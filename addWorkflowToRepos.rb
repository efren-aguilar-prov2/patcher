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
def getReposToInclude(org)
  reposToInclude = []
  # Read the list of repositories to include from a text file
  repoIncludeFile = 'include-repos.txt'
  if File.exist?(repoIncludeFile)
    puts "\nFile #{repoIncludeFile} exists, using it to filter Repos in the Source Org\n\n"
    reposToInclude = File.readlines(repoIncludeFile).map(&:chomp).reject { |line| line.strip.empty? || line.start_with?("#") }
    reposToInclude.map! { |repo| "#{org}/#{repo}" } # add in org/ to each repo name
  else
    puts "\nFile #{repoIncludeFile} does not exist. Processing ALL Repos in the Source Org\n\n"
    reposToInclude = $client.org_repos(org).map(&:full_name)
  end
  return reposToInclude
end # getReposToInclude

def getReposToExclude(org)
  reposToExclude = []
  # Read the list of repositories to exclude from a text file
  repoExcludeFile = 'exclude-repos.txt'
  if File.exist?(repoExcludeFile)
    puts "\nFile #{repoExcludeFile} exists, using it to filter Repos in the Source Org\n\n"
    reposToExclude = File.readlines(repoExcludeFile).map(&:chomp).reject { |line| line.strip.empty? || line.start_with?("#") }
    reposToExclude.map! { |repo| "#{org}/#{repo}" } # add in org/ to each repo name
  else
    puts "\nFile #{repoExcludeFile} does not exist. Processing ALL Repos that were included\n\n"
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
def create_output_folders()
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


##############################################################################################################
def reportOnExistingDevOpsPRs(repo, devopsPrefix)
  existingPRs = $client.pull_requests(repo, state: 'all')
  existingPRs.each do |pr|
    if pr.head.ref.start_with?(devopsPrefix)
      log($prs_csv, "#{repo},#{pr.head.ref},#{pr.state},#{pr.merged_at},#{pr.html_url}", false)
    end
  end
end # end of reportOnExistingDevOpsPRs

##############################################################################################################
# dump out api rate limit used, and remaining
def reportRateLimit(extraMsg)
  rateLimit = $client.rate_limit!
  puts "::: API Rate Limit: #{extraMsg}: #{rateLimit.remaining} of #{rateLimit.limit} requests remaining. Resets at: #{rateLimit.resets_at}"
end # end of reportRateLimit

##############################################################################################################
##############################################################################################################
def main()
  setupOctokit()
  org = 'PSJH-Dev'
  devopsPrefix = 'qqqGitHubAdminOps_' # if all branches we create have a unique prefix, we can find them later
  branchName =  devopsPrefix + 'patchNumber48'
  # TODO: Replace this with a pull from a markdown file
  pr_name = "GitHub Admins patching repo..."
  debug_flag = true
  create_output_files(org)
  repos = retrieveRepos(org)
  # TODO: Allow ability to pull files from a specific directory. These can act like projects. AKA change cwd
  # TODO: The script needs to maintain status of all repo prs. It should not attempt a PR if one already exists. BUT it should update status if one is found.
  repos.each_with_index do |repo, index|
    reportRateLimit("repo") if index % 50 == 0
    suspend_s = 5
    begin
      if !repo_exists?($client, repo)
        log($output_csv,"#{repo},warning,Repo does not exist", true)
        next
      end
      # TODO: This is next
      #TODO: Check if the PR already exists. If it does, update the status of the PR. If it does not, create the new PR

      mainBranch = $client.branch(repo, $client.repository(repo).default_branch)

      if !branch_exists?($client, repo, branchName)
        $client.create_ref(repo, "refs/heads/#{branchName}", mainBranch.commit.sha)
      end

      numberOfFilesAdded = addFilesToRepo(repo, branchName)
      # reportOnExistingDevOpsPRs(repo, devopsPrefix) # report on existing PRs before creating a new one
      thePR = create_pull_request(repo, mainBranch, branchName, pr_name)
      mergeSHA=mergePR(repo, thePR)
      validateFilesWereAdded(repo, mergeSHA) if debug_flag


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
