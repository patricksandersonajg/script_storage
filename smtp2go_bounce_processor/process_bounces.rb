require 'csv'
require 'date'

# This is a helper script that takes in the .txt attachments of the weekly bounce report summary email from SMTP2GO.
# It expects those files in a directory named as the iso date (yyyy-mm-dd), in the DATA_FOLDER (see variables below).
# A master csv is kept in the data folder, recording each email address and how many times we've encountered it.

# After processing you'll get a summary output which you can use to copy and paste into Outlook, as you forward the SMTP2GO email with it's attachments onto the relevant people (defined in CLIENT_INFO_CSV).
# Those people should then cleanse their data - if we see repeat offenders listed in the summary it means they haven't cleansed their data since last time, and that will have negatively impacted our sender reputation.

# Usage: Will work with any version of Ruby above 2.6. Run with something like: `ruby process_bounces 2026-02-19`

DATA_FOLDER = '/Volumes/gbs uk/Communications/Bulk email processing/smtp2go_weekly_bounces/source_files'
CLIENT_INFO_CSV = File.join(DATA_FOLDER, 'client_info.csv') # Mapping sender email addresses to clients and responsible people
EMAIL_INTRO_TEXT = File.join(DATA_FOLDER, 'email_intro_text.txt') # The standard text for pasting into the email to inform CST about what to do.
MASTER_CSV = File.join(DATA_FOLDER, 'all_bad_emails.csv')


# Run through a collection of .txt files in the iso-date named folder.
def process_directory(directory)
  data_filepath = File.join(DATA_FOLDER, directory)

  unless Dir.exist?(data_filepath)
    puts "Error: Directory '#{data_filepath}' does not exist."
    exit 1
  end

  # Read the master list into a hash for quick lookup
  master_list = {}
  CSV.foreach(MASTER_CSV, headers: true) do |row|
    master_list[row['email_address']] = row.to_h
  end

  # Get the ISO date from the directory name
  iso_date = File.basename(data_filepath)

  # Summary data structure
  summary = Hash.new { |hash, key| hash[key] = { 'new' => Hash.new(0), 'repeat' => 0 } }

  # Process each file in the ISO date directory.
  Dir.glob(File.join(data_filepath, '*.txt')).each do |file|
    filename = File.basename(file) # Expect something like "noreply@domain.com_bounce.txt"
    sender_email, reason = filename.split('_', 2)
    reason = reason.sub('.txt', '')

    File.readlines(file).each do |line|
      email = line.strip

      if master_list.key?(email)
        # Likely a repeat offender...

        unless master_list[email]['first_seen'] == iso_date
          # If we haven't added them via the current file (and rerun this process)...
          summary[sender_email]['repeat'] += 1
        end

        # Update the last_seen date and increment sightings, if it's not already updated
        if master_list[email]['last_seen'] != iso_date
          master_list[email]['last_seen'] = iso_date
          master_list[email]['sightings'] = master_list[email]['sightings'].to_i + 1
        end
      else
        # A new offender, add them to the list.
        master_list[email] = {
          'email_address' => email,
          'sender_email' => sender_email,
          'reason' => reason,
          'first_seen' => iso_date,
          'last_seen' => iso_date,
          'sightings' => 1
        }
        summary[sender_email]['new'][reason] += 1
      end
    end
  end

  # Write the updated master list back to the CSV
  CSV.open(MASTER_CSV, 'w') do |csv|
    csv << ['email_address', 'sender_email', 'reason', 'first_seen', 'last_seen', 'sightings']
    master_list.each_value do |row|
      csv << row.values
    end
  end

  if summary.count.positive?
    puts "\n----------------------------\n"
    puts "Copy/Paste the test below into the forwarded SMTP2GO bounces email"
    puts "Then replace names with the @tag versions, and make any edits you see fit."
    puts "To make changes to this text and the mapping of projects -> people, edit the files in: "
    puts "#{DATA_FOLDER}"
    puts "\n----------------------------\n"

    output_email_intro_text

    puts "\n\n\n"
    summary.each do |sender_email, data|
      puts "\n #{ bold(client_details_from_file(sender_email)) }"
      data['new'].each do |reason, count|
        puts "  • New #{reason}s: #{count}" if count > 0
      end
      puts bold("  • Repeat offenders: #{data['repeat']}") if data['repeat'] > 0
    end
  else
    puts "Nothing new to report, have you already run this process for #{iso_date}? (Repeat offenders aren't reported if they first occurred in the current target date's files.)"
   end
end


def bold(text)
  # Slightly dirty way of getting bold font, but it will survive a copy-paste into Outlook.
  text.tr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', '𝐀𝐁𝐂𝐃𝐄𝐅𝐆𝐇𝐈𝐉𝐊𝐋𝐌𝐍𝐎𝐏𝐐𝐑𝐒𝐓𝐔𝐕𝐖𝐗𝐘𝐙𝐚𝐛𝐜𝐝𝐞𝐟𝐠𝐡𝐢𝐣𝐤𝐥𝐦𝐧𝐨𝐩𝐪𝐫𝐬𝐭𝐮𝐯𝐰𝐱𝐲𝐳')
end

# Validate if the input is a valid ISO date (yyyy-mm-dd)
def valid_iso_date?(date_string)
  begin
    Date.iso8601(date_string)
    true
  rescue ArgumentError
    false
  end
end

def client_details_from_file(sender_email)
  client_details = sender_email
  if File.exist?(CLIENT_INFO_CSV)
    CSV.foreach(CLIENT_INFO_CSV, headers: true) do |row|
      if row['sender_email'] == sender_email
        client_details = "#{row['client_name']} - #{row['contacts']}"
        break
      end
    end
  end
  return client_details
end

def output_email_intro_text
  # Expects plain text file with **markdown style notation** for bold sections
  if File.exist?(EMAIL_INTRO_TEXT)
    text = File.read(EMAIL_INTRO_TEXT)
    processed_text = text.gsub(/\*\*(.*?)\*\*/m) { bold($1) }
    puts "\n#{processed_text}"
  else
    puts "\nWarning: #{EMAIL_INTRO_TEXT} not found in #{DATA_FOLDER}"
  end
end



# Main script execution

input_date = ARGV[0]

unless valid_iso_date?(input_date)
  puts "Error: Expected an iso-date as an input (eg: 2026-02-17). Should match a directory name within #{DATA_FOLDER}/ which contains the smtp2go bounce txt files from their weekly email report."
  exit 1
end

# Ensure the master CSV exists, create blank if not.
unless File.exist?(MASTER_CSV)
  CSV.open(MASTER_CSV, 'w') do |csv|
    csv << ['email_address', 'sender_email', 'reason', 'first_seen', 'last_seen', 'sightings']
  end
end

process_directory(input_date)
puts "\nProcessing complete."