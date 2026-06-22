#!/usr/bin/env ruby
# frozen_string_literal: true

# AI written script, designed to speed up patching of rails projects.

# Use with something like:
# ruby patch_this.rb ~/workspace/my_ruby_app rails rack nokogiri

# Will do the initial stages for you, pushing to github and preparing a PR for you to create.
# Test them on staging before making live!


require 'open3'
require 'fileutils'
require 'shellwords'

# Simple logging helpers
def log(msg)
  puts "[INFO] #{msg}"
end

def github_compare_url(dir, branch)
  # Derive a GitHub compare URL from the 'origin' remote.
  out, _err, status = run('git remote get-url origin', chdir: dir, allow_failure: true)
  return nil unless status.success?

  remote = out.strip
  repo_path = nil

  # Support SSH form: git@github.com:owner/repo.git
  if (m = remote.match(%r{\Agit@github\.com:([^\s]+?)(?:\.git)?\z}))
    repo_path = m[1]
  # Support HTTPS form: https://github.com/owner/repo.git
  elsif (m = remote.match(%r{\Ahttps://github\.com/([^\s]+?)(?:\.git)?\z}))
    repo_path = m[1]
  end

  return nil unless repo_path

  "https://github.com/#{repo_path}/compare/#{branch}?expand=1"
end

def warn(msg)
  STDERR.puts "[WARN] #{msg}"
end

def error(msg)
  STDERR.puts "[ERROR] #{msg}"
end

def abort_with(msg, code = 1)
  error(msg)
  exit(code)
end

def usage!
  puts <<~USAGE
    Usage: patch_this.rb /path/to/ruby_project GEM_NAME [GEM_NAME ...]

    - Creates or reuses a branch named snyk_patching_<yyyy-mm> from the repo's main/master.
    - Runs `bundle update` for the specified gems.
    - Runs `snyk test` and reports status, failing the script if vulnerabilities are found.

    Special handling:
      - If 'puma' is included in the gem list, the script will ensure the Gemfile
        pins puma to "~> 7.2" before running bundle update (useful for repos
        still constrained to version 6.x).

    Examples:
      patch_this.rb ~/workspace/my_ruby_app rails rack
  USAGE
  exit(2)
end

def run(cmd, chdir: nil, allow_failure: false, env: {})
  log "Running: #{cmd}#{chdir ? " (in #{chdir})" : ''}"
  stdout_str = ''
  stderr_str = ''
  status = nil
  Dir.chdir(chdir || Dir.pwd) do
    stdout_str, stderr_str, status = Open3.capture3(env, cmd)
  end
  puts stdout_str unless stdout_str.nil? || stdout_str.empty?
  STDERR.puts stderr_str unless stderr_str.nil? || stderr_str.empty?
  if !allow_failure && !status.success?
    abort_with("Command failed (exit #{status.exitstatus}): #{cmd}")
  end
  [stdout_str, stderr_str, status]
end

def which(cmd)
  exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
  ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
    exts.each do |ext|
      exe = File.join(path, "#{cmd}#{ext}")
      return exe if File.executable?(exe) && !File.directory?(exe)
    end
  end
  nil
end

def parse_ruby_version(str)
  # Extract first X.Y.Z occurrence
  m = str&.match(/(\d+\.\d+\.\d+)/)
  m ? m[1] : nil
end

def required_ruby_version(project_path)
  # Prefer .ruby-version file
  rv_file = File.join(project_path, '.ruby-version')
  if File.exist?(rv_file)
    v = File.read(rv_file).strip
    v = parse_ruby_version(v)
    return v if v
  end

  # Fallback: parse Gemfile for a pinned ruby directive (ruby "3.4.2")
  gemfile = File.join(project_path, 'Gemfile')
  if File.exist?(gemfile)
    File.foreach(gemfile) do |line|
      # Match exact pin only; ignore constraints like ">=" etc.
      if line =~ /^\s*ruby\s+["'](\d+\.\d+\.\d+)["']\s*$/
        return Regexp.last_match(1)
      end
    end
  end

  nil
end

def current_ruby_version
  out, _err, status = run('ruby -v', allow_failure: true)
  return nil unless status.success?
  parse_ruby_version(out)
end

def ensure_ruby_env(project_path)
  required = required_ruby_version(project_path)
  if required.nil?
    log 'No specific Ruby version found (.ruby-version or exact Gemfile ruby directive). Using current Ruby.'
    return { env: {}, exec: '' }
  end

  current = current_ruby_version
  if current == required
    log "Ruby #{required} already active."
    return { env: {}, exec: '' }
  else
    warn "Active Ruby is #{current || 'unknown'}, but project requires #{required}. Attempting to activate..."
  end

  # Try rbenv first
  if which('rbenv')
    # Install if missing
    out, _e, _s = run('rbenv versions --bare', allow_failure: true)
    installed = out.to_s.lines.map(&:strip)
    unless installed.include?(required)
      log "Installing Ruby #{required} via rbenv (if not present)..."
      run("rbenv install -s #{required}")
    end
    # Return env that selects the version for subsequent commands
    env = { 'RBENV_VERSION' => required }
    # Also export to current process for robustness
    ENV['RBENV_VERSION'] = required
    # Ensure bundler exists for this Ruby
    _o, _e2, st = run('rbenv exec bundle --version', env: env, allow_failure: true)
    unless st.success?
      log 'Bundler not available for the selected Ruby. Installing bundler...'
      run('rbenv exec gem install bundler', env: env)
      # Ensure shims updated
      run('rbenv rehash', env: env, allow_failure: true)
      run('rbenv exec bundle --version', env: env)
    end
    log "Using Ruby #{required} via rbenv."
    return { env: env, exec: 'rbenv exec ' }
  end

  abort_with("Required Ruby version #{required} not active and no supported version manager (rbenv) detected. Please activate Ruby #{required} and re-run.")
end

def bump_puma_version!(gemfile_path)
  return unless File.file?(gemfile_path)

  original = File.read(gemfile_path)

  # If it's already set to ~> 7.2 (or a narrower ~> 7.2.x), do nothing
  already_ok = original.match(/^[ \t]*gem[ \t]+["']puma["'][ \t]*,[^\n]*~>\s*7\.2(\.[0-9]+)?["']/)
  return false if already_ok

  lines = original.lines
  changed = false

  lines.map! do |line|
    # Match a typical gem line for puma, capturing the arguments (if any)
    # Examples handled:
    #   gem 'puma'
    #   gem 'puma', '6.3.1'
    #   gem 'puma', '~> 6.0'
    #   gem 'puma', require: false
    #   gem 'puma', '6.3.1', require: false
    if line =~ /^[ \t]*gem[ \t]+(["'])puma\1(\s*,\s*(.+))?\s*$/
      args = Regexp.last_match(3)

      desired = "'~> 7.2'"

      if args.nil? || args.strip.empty?
        # No arguments beyond gem name; insert version constraint
        new_line = line.sub(/(["']puma["'])\s*$/) { |m| "#{m}, #{desired}" }
        changed = true unless new_line == line
        line = new_line
      else
        # There are existing arguments. Replace the first version string literal arg if present;
        # otherwise, prepend the desired version before the existing args list.
        # Detect a string literal as first arg within the args list.
        if args.lstrip.start_with?("'", '"')
          # Remove the first string literal entirely and rebuild args with normalized spacing
          rest = args.sub(/^\s*(["']).*?\1\s*,?\s*/, '')
          replacement = rest.strip.empty? ? ", #{desired}" : ", #{desired}, #{rest.strip}"
          new_line = line.sub(/,(\s*)#{Regexp.escape(args)}/, replacement)
          changed = true unless new_line == line
          line = new_line
        else
          # No immediate string version provided; insert desired before existing args
          new_line = line.sub(/(["']puma["'])\s*,\s*/) { |m| "#{m}#{desired}, " }
          changed = true unless new_line == line
          line = new_line
        end
      end
    end
    line
  end

  if changed
    File.write(gemfile_path, lines.join)
    log "Updated Gemfile: set puma version constraint to '~> 7.2'"
  end

  changed
end

def ensure_tool!(name, check_cmd: nil)
  if which(name).nil?
    abort_with("Required tool not found on PATH: #{name}")
  end
  return unless check_cmd
  _out, _err, status = run(check_cmd, allow_failure: true)
  abort_with("Tool check failed for #{name}") unless status.success?
end

def git_default_branch(dir)
  # Try origin/HEAD symbolic ref first
  out, _err, status = run('git symbolic-ref --quiet refs/remotes/origin/HEAD', chdir: dir, allow_failure: true)
  if status.success?
    # output like: refs/remotes/origin/main
    return out.strip.split('/').last
  end
  # Fallback: check if main exists, else master
  out, _err, status = run('git branch -r', chdir: dir, allow_failure: true)
  if status.success?
    remote_branches = out.lines.map { |l| l.strip.sub(/^origin\//, '') }
    return 'main' if remote_branches.include?('main')
    return 'master' if remote_branches.include?('master')
  end
  # Last resort: check local
  out, _err, status = run('git branch', chdir: dir, allow_failure: true)
  if status.success?
    local_branches = out.lines.map { |l| l.gsub('*', '').strip }
    return 'main' if local_branches.include?('main')
    return 'master' if local_branches.include?('master')
  end
  abort_with('Could not determine default branch (main/master)')
end

def git_current_branch(dir)
  out, _err, status = run('git rev-parse --abbrev-ref HEAD', chdir: dir, allow_failure: true)
  abort_with('Not a git repository or cannot determine current branch') unless status.success?
  out.strip
end

def ensure_clean_worktree(dir)
  _out, _err, status = run('git diff --quiet', chdir: dir, allow_failure: true)
  unless status.success?
    abort_with('Working tree has unstaged changes. Please commit/stash before running this script.')
  end
  _out, _err, status = run('git diff --cached --quiet', chdir: dir, allow_failure: true)
  unless status.success?
    abort_with('Index has staged changes. Please commit/stash before running this script.')
  end
end

def ensure_branch_from_default(dir, branch_name)
  current = git_current_branch(dir)
  return current if current == branch_name

  default_branch = git_default_branch(dir)
  log "Default branch detected: #{default_branch}"

  # fetch latest and fast-forward default
  run('git fetch --prune --quiet origin', chdir: dir)
  run("git checkout #{default_branch}", chdir: dir)
  run('git pull --ff-only', chdir: dir)

  # create/reset the target branch from default
  run("git checkout -B #{branch_name}", chdir: dir)
  branch_name
end

def main
  usage! if ARGV.length < 2

  project_path = File.expand_path(ARGV.shift)
  gems = ARGV.dup

  abort_with("Project path does not exist: #{project_path}") unless Dir.exist?(project_path)

  # Ensure required tools are available
  ensure_tool!('git', check_cmd: 'git --version')
  ensure_tool!('bundle', check_cmd: 'bundle --version')
  ensure_tool!('snyk', check_cmd: 'snyk --version')

  # Validate project has a Gemfile
  gemfile = File.join(project_path, 'Gemfile')
  abort_with("No Gemfile found in project path: #{project_path}") unless File.exist?(gemfile)

  # Ensure correct Ruby version is selected before bundler operations
  ruby_ctx = ensure_ruby_env(project_path)

  # Ensure clean worktree before switching/creating branches
  ensure_clean_worktree(project_path)

  # Prepare branch
  branch_suffix = Time.now.strftime('%Y-%m')
  branch_name = "snyk_patching_#{branch_suffix}"
  created_branch = ensure_branch_from_default(project_path, branch_name)
  log "On branch: #{created_branch}"

  # Run bundle update for specified gems
  log "Updating gems: #{gems.join(', ')}"
  exec_prefix = ruby_ctx[:exec] || ''
  exec_env    = ruby_ctx[:env]  || {}

  # If puma is included in the gem targets, ensure Gemfile is bumped to '~> 7.2' first
  if gems.map(&:downcase).include?('puma')
    begin
      bump_puma_version!(gemfile)
    rescue => e
      warn "Failed to adjust puma version in Gemfile automatically: #{e.message}. Proceeding with bundle update."
    end
  end

  run("#{exec_prefix}bundle update #{gems.map { |g| Shellwords.escape(g) }.join(' ')}", chdir: project_path, env: exec_env)

  # NOTE: Do not commit yet. We will only commit & push if Snyk passes.

  # Run Snyk test only against the Ruby Gemfile to avoid other ecosystems (e.g., npm)
  log 'Running Snyk test (Gemfile via bundler only)...'
  snyk_out, _err, snyk_status = run('snyk test --file=Gemfile', chdir: project_path, allow_failure: true)

  puts snyk_out

  if snyk_status.success?
    log 'Snyk test passed: No known vulnerabilities found.'

    # Commit and push changes if there are any
    # Detect working tree changes
    status_out, _se, _st = run('git status --porcelain', chdir: project_path, allow_failure: true)
    if status_out.strip.empty?
      log 'No changes detected; nothing to commit.'
      exit(0)
    end

    # Stage typical files changed by bundler
    run('git add Gemfile.lock Gemfile', chdir: project_path, allow_failure: true)

    # Verify if anything is staged to commit
    diff_cached_out, _e2, _ = run('git diff --cached --name-only', chdir: project_path, allow_failure: true)
    if diff_cached_out.strip.empty?
      log 'No staged changes to commit after update; exiting.'
      exit(0)
    end

    commit_msg = "Snyk patching of gems: #{gems.join(' ')}"
    run("git commit -m #{Shellwords.escape(commit_msg)}", chdir: project_path, allow_failure: false)

    # Confirm before pushing
    print "About to push branch '#{created_branch}' to origin. Continue? [y/N]: "
    answer = $stdin.gets&.strip&.downcase
    unless answer == 'y'
      log 'Push cancelled by user. Commit remains local.'
      exit(0)
    end

    # Push to origin on the working branch; set upstream if needed
    begin
      run("git push -u origin #{created_branch}", chdir: project_path, allow_failure: false)
    rescue SystemExit
      # Fallback: try a plain push if upstream already set or other minor issues
      run('git push', chdir: project_path, allow_failure: true)
    end

    # Final action: provide PR creation URL (no confirmation required)
    begin
      url = github_compare_url(project_path, created_branch)
      if url
        log 'Please visit the following URL to create a draft PR:'
        puts url
      else
        warn "Could not determine GitHub remote URL. Please open your repository on GitHub and create a PR from branch '#{created_branch}'."
      end
    rescue => e
      warn "Unexpected error while generating PR URL: #{e.message}"
    end

    exit(0)
  else
    warn 'Snyk test reported vulnerabilities or failed to run.'
    # Try to detect common auth issue
    if snyk_out =~ /authentication/i
      warn 'It looks like Snyk authentication may be required. Run `snyk auth` and try again.'
    end
    exit(1)
  end
end

main if __FILE__ == $PROGRAM_NAME
