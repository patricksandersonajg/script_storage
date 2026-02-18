require 'csv'
require 'date'

# Put the txt files from a weekly smtp2go bounce report in a directory within DATA_FOLDER named as the iso date.
# Run this script with something like `ruby process_bounces.rb 2026-02-18`

# Expect a nice output you can copy into Outlook, to forward the SMTP2GO onto the relevant people to action.

# Details about who's responsible for which client are in CLIENT_INFO_CSV


DATA_FOLDER = 'data_folder'
MASTER_CSV = File.join(DATA_FOLDER, 'all_bad_emails.csv')
CLIENT_INFO_CSV = File.join(DATA_FOLDER, 'client_info.csv')

# Ensure the master CSV exists
unless File.exist?(MASTER_CSV)
  CSV.open(MASTER_CSV, 'w') do |csv|
    csv  ['email_address', 'sender_email', 'reason', 'first_seen', 'last_seen', 'sightings']
  end
end

# Function to process a directory of files
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

  # Process each file in the directory
  Dir.glob(File.join(data_filepath, '*.txt')).each do |file|
    # Extract sender email and reason from the file name
    filename = File.basename(file)
    sender_email, reason = filename.split('_', 2)
    reason = reason.sub('.txt', '')
    puts "\n\nChecking #{filename}\n\n"

    # Read the email addresses from the file
    File.readlines(file).each do |line|
      email = line.strip

      if master_list.key?(email) # This is a repeat offender, we've seen them before.
        puts "Email #{email} was first reported on #{master_list[email]['first_seen']}, has been seen #{master_list[email]['sightings']} times since, most recently #{master_list[email]['last_seen']}"
        summary[sender_email]['repeat'] += 1

        if master_list[email]['last_seen'] != iso_date
          # If this is the first run of this file, update the dates and counts.
          master_list[email]['last_seen'] = iso_date
          master_list[email]['sightings'] = master_list[email]['sightings'].to_i + 1
        end

      else
        # If the email is not in the master list, add it
        master_list[email] = {
          'email_address' => email,
          'sender_email' => sender_email,
          'reason' => reason,
          'first_seen' => iso_date,
          'last_seen' => iso_date,
          'sightings' => 1
        }
        # Update the summary for new emails
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

  # Print the summary
  puts "\n----------------------------"
  puts "\nSummary of processing:"
  summary.each do |sender_email, data|
    puts "\n#{client_details_from_file(sender_email)}"
    data['new'].each do |reason, count|
      puts "  New #{reason.capitalize}: #{count}" if count > 0
    end
    puts "  Repeat offenders: #{data['repeat']}" if data['repeat'] > 0
  end
end

def client_details_from_file(sender_email)
  cst = sender_email # If no record found, the sender_email is better than nothing
  if File.exist?(CLIENT_INFO_CSV)
    CSV.foreach(CLIENT_INFO_CSV, headers: true) do |row|
      if row['sender_email'] == sender_email
        cst = "#{row['client_name']} - #{row['contacts']}"
        break
      end
    end
  end
  return cst
end


# Main script execution
if ARGV.length != 1
  puts "Usage: ruby process_bad_emails.rb iso-date named directory (eg: 2026-02-17)"
  exit 1
end

process_directory(ARGV[0])
puts "\nProcessing complete. Master list updated."