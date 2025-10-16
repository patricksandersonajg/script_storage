require 'fileutils'
require 'open3'
require 'date'
require 'rainbow'
require 'set'

# Timesheet from Git helper.

# Made entirely with AI to prove it can be done - the only human edits have been adding these header comments.

# Run this in your workspace dir, it'll look at all your git repos and give you a day-by-day summary of your git commits by project.

# It should work on any version of ruby from 2.7 to 3.4 and above.
# You may need to install the required gems first (`gem install rainbow` etc), then run this script with:

# ruby timesheet_from_git




# Define global parameters
workspace_dir = '../'
committer_name = 'patrick'
today = Date.today
$start_of_week = today - today.wday # Calculate the most recent Sunday
days_of_week_full = %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday]

# Function to execute shell commands
def execute_command(command)
  stdout, stderr, status = Open3.capture3(command)
  raise stderr unless status.success?
  stdout.strip
end

# Function to find git repositories
def find_git_repos(directory)
  repos = []
  Dir.foreach(directory) do |entry|
    next if entry == '.' || entry == '..'
    
    path = File.join(directory, entry)
    if File.directory?(path)
      if File.exist?(File.join(path, '.git'))
        repos << path
      else
        repos.concat(find_git_repos(path))
      end
    end
  end
  repos.sort # Sort repositories alphabetically
end

# Function to get branches with recent activity and commit count
def get_git_info(repo_path, committer_identifier, hide_branch_merges: true)
   Dir.chdir(repo_path) do
    # Get all branches
    all_branches = execute_command('git for-each-ref --format="%(refname:short)" refs/heads').split("\n")
    
    # Initialize a hash to store commits and merges by day
    commits_by_day = Hash.new { |hash, key| hash[key] = Set.new }
    
    # Iterate over each branch to collect commits and merges
    all_branches.each do |branch|
      # Filter commits (including merges) by committer name or email containing the identifier
      recent_commits = execute_command("git log #{branch} --since='#{$start_of_week}' --pretty=format:'%ad %s' --author='#{committer_identifier}' --date=short").split("\n")
      recent_merges = execute_command("git log #{branch} --since='#{$start_of_week}' --pretty=format:'%ad %s' --merges --author='#{committer_identifier}' --date=short").split("\n")
      
      # Combine commits and merges
      recent_activity = (recent_commits + recent_merges).uniq
      
      # Optionally filter out branch merges
      if hide_branch_merges
        recent_activity.reject! do |activity|
          # Strict regex to match branch merge messages
          activity.match?(/^*Merge branch */)
        end
      end
      
      # Organize commits and merges by day
      recent_activity.each do |activity|
        date, message = activity.split(' ', 2)
        commits_by_day[date] << message
      end
    end
    
    # Get branches with recent commits or merges by the specified committer identifier
    branches_with_recent_activity = all_branches.select do |branch|
      !execute_command("git log #{branch} --since='#{$start_of_week}' --pretty=format:'%s' --author='#{committer_identifier}'").empty? ||
      !execute_command("git log #{branch} --since='#{$start_of_week}' --pretty=format:'%s' --merges --author='#{committer_identifier}'").empty?
    end
    
    { branches: branches_with_recent_activity, commits_by_day: commits_by_day }
  end
end



# Function to format date
def format_date(date_str)
  date = Date.parse(date_str)
  day_name = date.strftime('%A') # Full day name
  formatted_date = date.strftime("%Y-%m-%d (#{day_name})")
  formatted_date
end

# Initialize summary table
summary_table = Hash.new { |hash, key| hash[key] = Hash.new(false) }
commits_summary = Hash.new { |hash, key| hash[key] = Hash.new { |h, k| h[k] = Set.new } }

# Find all git repositories in the workspace
git_repos = find_git_repos(workspace_dir)

# Iterate through each git repository in alphabetical order
git_repos.each do |repo_path|

  begin
    git_info = get_git_info(repo_path, committer_name)
    next if git_info[:commits_by_day].empty?
    
    project_name = File.basename(repo_path)[0, 32] # Truncate project name to 32 characters
    
    git_info[:commits_by_day].each do |day, commits|
      formatted_date = format_date(day)
      day_name = Date.parse(day).strftime('%A')
      
      # Update summary table
      summary_table[project_name][day_name] = true
      
      # Update commits summary
      commits_summary[day_name][project_name].merge(commits)
    end
    
  rescue => e
    puts Rainbow("Error processing #{repo_path}: #{e.message}").red.bright
  end
end

# Output human-friendly summary
puts "\n" + Rainbow("Weekly Work Summary:").underline.bright
days_of_week_full.each do |day_name|
  next unless commits_summary.key?(day_name)
  
  puts Rainbow("On #{day_name} you did:").cyan.bright
  commits_summary[day_name].each do |project_name, commit_messages|
    puts Rainbow("#{commit_messages.size} commits on #{project_name}:").bright.bold
    puts Rainbow("with the following commit messages:").green
    commit_messages.each do |message|
      puts Rainbow("* #{message}").yellow
    end
  end
  puts "-" * 40
end

# Output summary table
puts "\n" + Rainbow("Summary Table:").underline.bright
header = [Rainbow("Project".ljust(32)).cyan.bright] + days_of_week_full.map { |day| Rainbow(day[0, 3]).yellow }
puts header.join("\t")

summary_table.each do |project, days|
  row = [Rainbow(project.ljust(32)).cyan]
  days_of_week_full.each do |day|
    row << (days[day] ? Rainbow(" X").green : " ") # Add space before "X"
  end
  puts row.join("\t")
end