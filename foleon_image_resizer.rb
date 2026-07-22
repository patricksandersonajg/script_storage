#!/usr/bin/env ruby
# frozen_string_literal: true


# You need imagemagik installed to run this. Likely you can install it with
# brew install imagemagick
# gem install mini_magick

# Then run this with something like
# ruby foleon_image_resizer.rb /path_to/assets_of_www_mybenefitsnow_com_site_name

# The Bedrocc site conversion requires an image per benefit page - in thumbnail size and hero size.

# Intention is to point it at a folder of images exported from a Foleon site, and it'll generate thumbnail and hero sized versions of each asset.

# You probably want to go through and delete any unsuitible images like icons that have crept in, and upload those seperately.

require 'fileutils'
require 'etc'

begin
  require 'mini_magick'
rescue LoadError
  warn 'ERROR: mini_magick gem is required. Install with: gem install mini_magick'
  exit 2
end

begin
  require 'parallel'
rescue LoadError
  warn 'ERROR: parallel gem is required. Install with: gem install parallel'
  exit 2
end

# Configuration defaults
# Thumbnail config
MAX_WIDTH = 450
OUTPUT_DIR_NAME = 'thumbnails' # Can be changed if needed later
THUMB_PREFIX = 'thumb_'

# Hero images config
HERO_MAX_WIDTH = 1200
HERO_OUTPUT_DIR_NAME = 'heroes'
HERO_PREFIX = 'hero_'

VERBOSE = true

VALID_EXTS = %w[.png .jpg .jpeg .svg].freeze

def log(msg)
  puts(msg) if VERBOSE
end

def ensure_dir(path)
  FileUtils.mkdir_p(path)
end

def image_allowed?(path)
  VALID_EXTS.include?(File.extname(path).downcase)
end

def target_path_with(input_root, file_path, out_dir_name, prefix)
  rel = file_path.sub(/^#{Regexp.escape(input_root)}\/?/, '')
  rel_dir = File.dirname(rel)
  base = File.basename(rel, File.extname(rel))
  out_dir = File.join(input_root, out_dir_name, rel_dir)
  ensure_dir(out_dir)
  File.join(out_dir, "#{prefix}#{base}.jpg")
end

def thumb_target_path(input_root, file_path)
  target_path_with(input_root, file_path, OUTPUT_DIR_NAME, THUMB_PREFIX)
end

def hero_target_path(input_root, file_path)
  target_path_with(input_root, file_path, HERO_OUTPUT_DIR_NAME, HERO_PREFIX)
end

def process_bitmap_to_jpeg(src_path, dest_path, max_w)
  # Returns [src_path, true/false, error_or_nil]
  begin
    image = MiniMagick::Image.open(src_path)
    # Ignore if source width is smaller than target width
    if image.width && image.width < max_w
      log "SKIP #{src_path} :: width #{image.width}px < target #{max_w}px"
      return [src_path, true, nil]
    end
    # Only downscale: the '>' prevents upscaling
    image.combine_options do |c|
      c.resize "#{max_w}x>"
      c.strip # remove metadata/profiles (may drop ICC; acceptable per request)
      c.quality '85'
      c.interlace 'JPEG' # progressive
    end
    image.format 'jpg'
    image.write(dest_path)
    [src_path, true, nil]
  rescue => e
    [src_path, false, "Bitmap resize failed: #{e.message}"]
  end
end

# This probably isn't necessary as svgs should be vectors...however I have seen jpgs encoded inside svgs in the past. And as AI code is cheap, it's here just in case.
def process_svg_to_jpeg(src_path, dest_path, max_w)

  # Returns [src_path, true/false, error_or_nil]
  begin
    # MiniMagick (ImageMagick) can rasterize SVG if properly delegated.
    # We request rasterization with target width, no upscaling beyond original rendered size isn't
    # straightforward for vector assets, but resize will clamp to max_w.
    image = MiniMagick::Image.open(src_path)
    # If ImageMagick can report an intrinsic width, skip when smaller than target
    if image.width && image.width < max_w
      log "SKIP #{src_path} :: width #{image.width}px < target #{max_w}px"
      return [src_path, true, nil]
    end
    image.combine_options do |c|
      c.resize "#{max_w}x>"
      c.strip
      c.quality '85'
      c.interlace 'JPEG'
    end
    image.format 'jpg'
    image.write(dest_path)
    [src_path, true, nil]
  rescue => e
    [src_path, false, "SVG rasterize failed (is librsvg/ImageMagick SVG delegate installed?): #{e.message}"]
  end
end

def collect_files(input_root)
  files = []
  Dir.glob(File.join(input_root, '**', '*'), File::FNM_DOTMATCH).each do |p|
    next unless File.file?(p)
    # Skip our output directory to avoid recursive processing of generated thumbnails
    dir_parts = File.dirname(p).split(File::SEPARATOR)
    next if dir_parts.include?(OUTPUT_DIR_NAME) || dir_parts.include?(HERO_OUTPUT_DIR_NAME)
    files << p if VALID_EXTS.include?(File.extname(p).downcase)
  end
  files
end

def worker_variant(src_path, input_root, max_w, out_dir_name, prefix)
  return [src_path, false, 'Unsupported file type (allowed: png, jpg, jpeg, svg)'] unless image_allowed?(src_path)

  dest_path = target_path_with(input_root, src_path, out_dir_name, prefix)
  ext = File.extname(src_path).downcase
  if %w[.jpg .jpeg .png].include?(ext)
    process_bitmap_to_jpeg(src_path, dest_path, max_w)
  elsif ext == '.svg'
    process_svg_to_jpeg(src_path, dest_path, max_w)
  else
    [src_path, false, 'Unsupported file type']
  end
end

# Backwards-compatible worker (thumbnails pass)
def worker(src_path, input_root, max_w)
  worker_variant(src_path, input_root, max_w, OUTPUT_DIR_NAME, THUMB_PREFIX)
end

def main(argv)
  if argv.length != 1
    warn 'Usage: ruby script_storage/foleon_image_resizer.rb <directory>'
    return 2
  end

  input_root = File.expand_path(argv[0])
  unless File.directory?(input_root)
    warn "ERROR: Not a directory: #{input_root}"
    return 2
  end

  log "Scanning: #{input_root}"
  files = collect_files(input_root)
  if files.empty?
    log 'No matching images found.'
    return 0
  end

  log "Discovered #{files.length} candidate files."

  successes = 0
  failures = 0
  errors = []

  procs = [Etc.nprocessors, 1].max
  
  # Pass 1: thumbnails (450px)
  log "Processing thumbnails with #{procs} workers, max width #{MAX_WIDTH}px -> JPG"
  Parallel.each(files, in_processes: procs) do |src|
    begin
      _src, ok, err = worker_variant(src, input_root, MAX_WIDTH, OUTPUT_DIR_NAME, THUMB_PREFIX)
      if ok
        log "OK [thumb] #{src}"
        successes += 1
      else
        log "FAIL [thumb] #{src} :: #{err}"
        failures += 1
        errors << [src, err || 'unknown error']
      end
    rescue => e
      msg = "Worker crashed: #{e.message}"
      log "FAIL [thumb] #{src} :: #{msg}"
      failures += 1
      errors << [src, msg]
    end
  end

  # Pass 2: heroes (1200px)
  log "Processing heroes with #{procs} workers, max width #{HERO_MAX_WIDTH}px -> JPG"
  Parallel.each(files, in_processes: procs) do |src|
    begin
      _src, ok, err = worker_variant(src, input_root, HERO_MAX_WIDTH, HERO_OUTPUT_DIR_NAME, HERO_PREFIX)
      if ok
        log "OK [hero ] #{src}"
        successes += 1
      else
        log "FAIL [hero ] #{src} :: #{err}"
        failures += 1
        errors << [src, err || 'unknown error']
      end
    rescue => e
      msg = "Worker crashed: #{e.message}"
      log "FAIL [hero ] #{src} :: #{msg}"
      failures += 1
      errors << [src, msg]
    end
  end

  puts
  puts 'Summary:'
  puts "  Total candidates: #{files.length}"
  puts "  Operations run:  #{files.length * 2} (thumbs + heroes)"
  puts "  Succeeded ops:   #{successes}"
  puts "  Failed ops:      #{failures}"
  unless errors.empty?
    puts
    puts 'Errors:'
    errors.first(100).each do |src, msg|
      puts "  - #{src}: #{msg}"
    end
    if errors.length > 100
      puts "  ... and #{errors.length - 100} more"
    end
  end

  failures.zero? ? 0 : 1
end

if __FILE__ == $PROGRAM_NAME
  exit(main(ARGV))
end
