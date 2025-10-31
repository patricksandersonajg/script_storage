require 'time'
require 'open3'

# Will check the host's HTTPS status every minute, and log any changes - basically keeping a record of when the host is up or down.

# Any status code that begins with a 2 or 3 is considered to be 'Up' as it's an okay or a redirect response.

# Status code 000 = timeout

# Example usage: `ruby uptime_monitor.rb exampledomain.com`

# Configuration
DEFAULT_HOST = 'synergist.emea.ajgco.com' # Default host if none is provided via command line
LOG_FILE = 'host_status.log'
CHECK_INTERVAL = 60 # in seconds
CURL_TIMEOUT = 10 # Timeout for curl request in seconds

# Get the host from command-line arguments or use the default
host = ARGV[0] || DEFAULT_HOST
url = "https://#{host}"

# Initialise variables
previous_state = nil
previous_status_code = nil

# Function to log messages to the file
def log_status(message)
  timestamp = Time.now.utc.iso8601
  File.open(LOG_FILE, 'a') do |file|
    file.puts("[#{timestamp}] #{message}")
  end
end

# Function to check the host's HTTP status using curl
def check_host_status(url, timeout)
  # Run the curl command with a timeout
  stdout, stderr, _status = Open3.capture3("curl --max-time #{timeout} -o /dev/null -s -w \"%{http_code}\" #{url}")
  status_code = stdout.strip
  is_up = status_code.start_with?("2", "3") # Consider the host "up" if the status code starts with 2 or 3
  [is_up, status_code]
end

# Log startup message
log_status("Monitoring started for host: #{host}")

# Main loop
loop do
  begin
    # Check the host's status
    current_state, current_status_code = check_host_status(url, CURL_TIMEOUT)

    # Print tick or cross to terminal
    if current_state
      print "✔ " # Tick for successful response
    else
      print "✘ " # Cross for failed response
    end

    # Check for state or status code change
    if current_state != previous_state || current_status_code != previous_status_code
      if current_state
        log_status("Host #{host} is UP (Status Code: #{current_status_code})")
      else
        log_status("Host #{host} is DOWN (Status Code: #{current_status_code})")
      end
      previous_state = current_state
      previous_status_code = current_status_code
    end
  rescue StandardError => e
    log_status("Error occurred: #{e.message}")
  end

  # Wait for the next interval
  sleep(CHECK_INTERVAL)
end