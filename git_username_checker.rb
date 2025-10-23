require 'open3'

# Check the git username is set sensibly in all repos inside the workspace folder

workspace_dir = "/Users/ptsanderson/workspace/"
expected_name = "Patrick"

# Ensure the workspace directory exists
unless Dir.exist?(workspace_dir)
  puts "Workspace directory does not exist: #{workspace_dir}"
  exit 1
end

# Method to recursively find Git repositories and validate their Git user name
def find_git_repos(directory, workspace_dir, expected_name)
  Dir.foreach(directory) do |entry|
    next if entry == '.' || entry == '..' # Skip current and parent directory entries

    path = File.join(directory, entry)

    if File.directory?(path)
      if Dir.exist?(File.join(path, '.git')) # Check if it's a Git repository
        # Get the Git user name for the repository
        git_user_name = nil
        Dir.chdir(path) do
          stdout, stderr, status = Open3.capture3("git config user.name")
          git_user_name = stdout.strip if status.success?
        end

        # Print the project name (relative path) and Git user name
        relative_path = path.sub("#{workspace_dir}/", '') # Get relative path

        puts "\nProject: #{relative_path}"
        if git_user_name.nil? || git_user_name.empty?
          puts "  Git User Name: Not configured"
        elsif git_user_name != expected_name
          puts "  Git User Name: #{git_user_name} (ERROR: Does not match expected name '#{expected_name}')"
        else
          puts "  Git User Name: #{git_user_name}"
        end
      else
        # Recursively search subdirectories
        find_git_repos(path, workspace_dir, expected_name)
      end
    end
  end
end

# Start the recursive search from the workspace directory
find_git_repos(workspace_dir, workspace_dir, expected_name)