# This script adds files to multiple repositories in an organization.
# It uses the Octokit gem to interact with the GitHub API.
# The script performs the following steps:
# 1. Reads a list of repositories from a text file or retrieves all repositories in the organization.
# 2. Creates a new branch in each repository.
# 3. Adds files from the "patch_files" folder to the new branch.
# 4. Creates a pull request from the new branch to the default branch.
# 5. Merges the pull request and deletes the branch.
# 6. Validates that the files were successfully added to the default branch if a debug flag is true.
# 7. Reports on existing pull requests with a specific prefix.
# 8. Outputs the results to CSV files.
#
require 'octokit'
require 'csv'

##############################################################################################################
def log(file,msg,screenEcho)
  File.open(file, "a") do |file|
    file.puts(msg)
  end
  if screenEcho
    puts msg
  end
end

##############################################################################################################
def setupOctokit
  access_token = ENV['GH_PAT']
  if access_token.nil?
    puts "You need to set the GH_PAT environment variable to run this script"
    exit
  end
  $client = Octokit::Client.new(access_token: access_token)
  $client.auto_paginate = true
  reportRateLimit("beginning of run")
end

##############################################################################################################
def branch_exists?(client, repo, branch)
  client.ref(repo, "heads/#{branch}")
  true
rescue Octokit::NotFound
  false
end

##############################################################################################################
# Return the info for a pr if it exists, otherwise return nil
def get_pr_info(client, repo, pr_number)
  begin
    pr = client.pull_request(repo, pr_number)
    return pr
  rescue Octokit::NotFound
    return nil
  end
end

##############################################################################################################
def getReposToInclude(org)
  reposToInclude = []
  # Read the list of repositories to include from a text file
  repoIncludeFile = 'include-repos.txt'
  if File.exist?(repoIncludeFile)
    puts "File #{repoIncludeFile} exists, using it to filter Repos in the Source Org"
    reposToInclude = File.readlines(repoIncludeFile).map(&:chomp).reject { |line| line.strip.empty? || line.start_with?("#") }
    reposToInclude.map! { |repo| "#{org}/#{repo}" } # add in org/ to each repo name
  else
    puts "File #{repoIncludeFile} does not exist. Processing ALL Repos in the Source Org"
    reposToInclude = $client.org_repos(org).map(&:full_name)
  end
  return reposToInclude
end # getReposToInclude

def getReposToExclude(org)
  reposToExclude = []
  # Read the list of repositories to exclude from a text file
  repoExcludeFile = 'exclude-repos.txt'
  if File.exist?(repoExcludeFile)
    puts "File #{repoExcludeFile} exists, using it to filter Repos in the Source Org"
    reposToExclude = File.readlines(repoExcludeFile).map(&:chomp).reject { |line| line.strip.empty? || line.start_with?("#") }
    reposToExclude.map! { |repo| "#{org}/#{repo}" } # add in org/ to each repo name
  else
    puts "File #{repoExcludeFile} does not exist. Processing ALL Repos that were included"
  end
  return reposToExclude
end # getReposToExclude


##############################################################################################################
def retrieveRepos(org)
  repos = []
  repos += getReposToInclude(org)
  repos -= getReposToExclude(org)
  repos.sort!
  return repos
end # retrieveRepos

##############################################################################################################
def create_pull_request(repoFullName, mainBranch, patchBranchName, commitMsgPrName)
  # Create a pull request from the new branch to the default branch
  begin
    thePR = $client.create_pull_request(repoFullName, mainBranch.name, patchBranchName, commitMsgPrName)
    log($output_csv,"#{repoFullName},success,PR created: #{thePR.html_url}", true)
    return thePR
  rescue Octokit::UnprocessableEntity => e
    log($output_csv,"#{repoFullName},notice,PR already exists or failed to create", true)
  end
end

##############################################################################################################
def mergePR(repoFullName, thePR)
    return if thePR.nil?

    begin
      # $client.create_pull_request_review(repoFullName, thePR.number, event: 'APPROVE')
     mergedPR = $client.merge_pull_request(repoFullName, thePR.number)
      log($output_csv,"#{repoFullName},success,PR merged", true)
      $client.delete_branch(repoFullName, thePR.head.ref)
      # log($output_csv,"#{repoFullName},success,branch deleted", true)
    rescue Octokit::UnprocessableEntity => e
      # find an open PR for the branch with the right name
      log($output_csv,"#{repoFullName},warning,erorr occured: #{e.message}", true)
    end
    # puts "Merged PR SHA: #{mergedPR.sha}"
  mergedPR.sha
end

##############################################################################################################
def create_new_prs_file
  File.open($prs_csv, "w") do |file|
    file.puts("Repo,Branch,PR Num,State,Merged At,URL")
  end
end

##############################################################################################################
def create_output_files(org)
  create_output_folders()
  time = Time.new
  time = time.strftime("%Y%m%d_%H%M%S")

  $output_csv = "#{$output_folder}/#{org}_#{time}_output.csv"
  File.open($output_csv, "w") do |file|
    file.puts("Repo,Message Type,Message")
  end

  # Check if the PRs file already exists, if not create it
  $prs_csv = "#{$output_folder}/#{org}_prs.csv"
  unless File.exist?($prs_csv)
    puts "Creating PRs file: #{$prs_csv}"
    File.open($prs_csv, "w") do |file|
      file.puts("Repo,Branch,PR Num,State,Merged At,URL")
    end
  end
end #end of create_output_files


##############################################################################################################
def create_output_folders
  $output_folder = "_out"
  unless File.directory?($output_folder)
    Dir.mkdir($output_folder)
  end
  $patch_files_folder = "patch_files"
  unless File.directory?($patch_files_folder)
    Dir.mkdir($patch_files_folder)
  end
end #end of create_output_folders

##############################################################################################################
def repo_exists?(client, repo)
  client.repository(repo)
  true
rescue Octokit::NotFound
  false
end

##############################################################################################################
def addFilesToRepo(repo, branchName)
  fileCount = 0
  Dir.glob('patch_files/**/*' , File::FNM_DOTMATCH).each do |file|
    next if File.directory?(file) || File.basename(file) == '.DS_Store' #.DS_Store is a Mac thing

    fileContent = File.read(file)
    filePath = "#{file.sub('patch_files/', '')}" # Remove the first folder from the file path
    fileName = filePath.split('/').last # get just the text at the end after the last slash
    commitMsg = "DevOps adding/updating file #{fileName} [skip ci]"
    begin
      existing_file = $client.contents(repo, path: filePath, ref: branchName)
      $client.update_contents(repo, filePath, commitMsg, existing_file.sha, fileContent, branch: branchName)
      fileCount += 1
      # log($output_csv, "#{repo},success,File #{filePath} updated", true)
    rescue Octokit::NotFound
      # the files aren't there already, so create them
      $client.create_contents(repo, filePath, commitMsg, fileContent, branch: branchName)
      fileCount += 1
      # log($output_csv, "#{repo},success,File #{filePath} added", true)
    rescue Octokit::UnprocessableEntity => e
      log($output_csv, "#{repo},warning,Failed to add/update file #{filePath},#{e.message}", true)
    end
  end # end of Dir.glob
  log($output_csv, "#{repo},success,#{fileCount} files added to branch", true)
  fileCount # return the number of files added so they can be verified
end # end of addFilesToRepo

##############################################################################################################
def validateFilesWereAdded(repo, shaFromMerge)
  commit = $client.commit(repo, shaFromMerge)
  header = <<-__TEXT__
  Date: #{commit.commit.author.date}
  Message: #{commit.commit.message}
  ----- File(s) changed ----------------------
  __TEXT__
  commit.files.each do |file|
    header += "  File: ./#{file.filename}\n"
  end
  log($output_csv, "#{repo},debug,\n#{header}", true)
end


# dump out api rate limit used, and remaining
def reportRateLimit(extraMsg)
  rateLimit = $client.rate_limit!
  puts "::: API Rate Limit: #{extraMsg}: #{rateLimit.remaining} of #{rateLimit.limit} requests remaining. Resets at: #{rateLimit.resets_at}"
end # end of reportRateLimit


# Use the csv file to create a hash of repos and their statuses
def initialize_prs_hash
  $prs_hash = {}
  CSV.foreach($prs_csv, headers: true) do |row|
    $prs_hash[row['Repo']] = { 'Branch' => row['Branch'], 'PR Num' => row['PR Num'], 'State' => row['State'], 'MergedAt' => row['Merged At'], 'Url' => row['URL']}
  end
end

# Get the state of a repo from the prs hash, if it exists
def get_repo_state(repo)
  return $prs_hash[repo].nil? ? 'none' : $prs_hash[repo]['State']
end

def write_pr_hash_value_to_csv(repo)
  write_pr_to_csv(repo, $prs_hash[repo]['Branch'], $prs_hash[repo]['PR Num'], $prs_hash[repo]['State'], $prs_hash[repo]['MergedAt'], $prs_hash[repo]['Url'])
end

def write_pr_to_csv(repo, branch, pr_number, state, merged_at, url)
  File.open($prs_csv, "a") do |file|
    file.puts("#{repo},#{branch},#{pr_number},#{state},#{merged_at},#{url}")
  end
end

def get_default_branch(repo)
    branch = $client.branch(repo, $client.repository(repo).default_branch)
    return branch
  rescue Octokit::NotFound
    log($output_csv,"#{repo},warning,Repo does not exist. Skipping", true)
    return nil
end

def create_pr_branch(repo, branchSource, newBranchName)
    $client.create_ref(repo, "refs/heads/#{newBranchName}", branchSource.commit.sha)
  rescue Octokit::UnprocessableEntity => e
    if e.message.include?("Reference already exists")
      log($output_csv,"#{repo},warning,Branch #{newBranchName} already exists. Skipping creation.", true)
    else
      raise e
    end
end

def create_new_pr(repo, branchName)
  log($output_csv,"#{repo},notice,PR does not exist. Creating a new PR", true)
  mainBranch = get_default_branch(repo)
  # Return if the repo does not exist
  if mainBranch.nil?
    return
  end
  create_pr_branch(repo, mainBranch, branchName)
  addFilesToRepo(repo, branchName)
  thePR = create_pull_request(repo, mainBranch, branchName, pr_name)
  write_pr_to_csv(repo, branchName, thePR.number, thePR.state, thePR.merged_at, thePR.html_url)
end

def update_csv_with_newest_pr_info(repo)
  pr = get_pr_info($client, repo, $prs_hash[repo]['PR Num'])
  if pr.nil?
    # the PR doesn't exist, there may be an error in the CSV file
    log($output_csv,"#{repo},warning,PR#{$prs_hash[repo]['PR Num']} does not exist this may be an error in the original CSV file. Removing this record", true)
    next
  end
  log($output_csv,"#{repo},notice,PR already exists. Updating with newest stats pulled from API", true)
  write_pr_to_csv(repo, pr.head.ref, pr.number, pr.state, pr.merged_at, pr.html_url)

##############################################################################################################
def main
  setupOctokit()
  org = 'PSJH-Dev'
  devopsPrefix = 'qqqGitHubAdminOps_' # if all branches we create have a unique prefix, we can find them later
  branchName =  devopsPrefix + 'patchNumber48'
  # TODO: Replace this with a pull from a markdown file
  pr_name = "GitHub Admins patching repo..."
  debug_flag = true
  create_output_files(org)
  # Create a hash of the repos and their statuses from the prs file
  initialize_prs_hash()
  # Overwrite the prs file now that the hash has been created
  create_new_prs_file()
  repos = retrieveRepos(org)
  # TODO: Allow ability to pull files from a specific directory. These can act like projects. AKA change cwd
  repos.each_with_index do |repo, index|
    reportRateLimit("repo") if index % 50 == 0
    suspend_s = 5
    begin
      # If the pr is not in the csv file, it most likely has not been created
      if $prs_hash[repo].nil?
        create_new_pr(repo, branchName)
        next
      end
      # if the pr is in the csv file, check its current status if it has not been merged
      if $prs_hash[repo]['MergedAt'].nil?
       update_csv_with_newest_pr_info(repo)
      end
    rescue Octokit::TooManyRequests
      puts "Rate limit exceeded, sleeping for #{suspend_s} seconds"
      sleep suspend_s
      suspend_s = [suspend_s * 2, client.rate_limit.resets_in + 1].min
      retry
    end # begin-rescue block
  end # repos.each

  reportRateLimit("end of run")
end # main

main()