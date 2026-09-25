require "open3"
require "tmpdir"

# R8: a throwaway config repo for changeset specs -- a bare repo seeded with
# the empty decK file, the way `rake kong:seed_config_repo` seeds uat.git.
# Including it also points every Kong::GitClient at a working copy under the
# example's own temp dir, so no spec writes into storage/git_cache.
module BareGitRepo
  def self.included(base)
    base.around do |example|
      Dir.mktmpdir("bare-git-repo") do |dir|
        @bare_git_tmp = Pathname(dir)
        example.run
      end
    end

    base.before do
      original_new = Kong::GitClient.method(:new)
      allow(Kong::GitClient).to receive(:new) do |connection:, working_dir: nil|
        original_new.call(connection: connection, working_dir: working_dir || @bare_git_tmp.join("cache-#{connection.id}"))
      end
    end
  end

  def bare_git_repo(path:, select_tags:)
    repo = @bare_git_tmp.join("config-#{SecureRandom.hex(4)}.git")
    git!("init", "--bare", "--initial-branch=main", repo.to_s)
    scratch = @bare_git_tmp.join("seed-#{SecureRandom.hex(4)}")
    git!("clone", repo.to_s, scratch.to_s)
    file = scratch.join(path)
    FileUtils.mkdir_p(file.dirname)
    File.write(file, Kong::DeckDocument.serialize(Kong::DeckDocument.parse(nil, select_tags: select_tags)))
    git!("add", "-A", chdir: scratch)
    git!("-c", "user.name=kongctl", "-c", "user.email=kongctl@kong-integration.local", "commit", "-m", "Seed empty decK config", chdir: scratch)
    git!("push", "origin", "main", chdir: scratch)
    repo
  end

  def head_sha(repo)
    git!("rev-parse", "main", chdir: repo).strip
  end

  # Someone else pushed to the base branch after a changeset began.
  def push_empty_commit(repo)
    scratch = @bare_git_tmp.join("push-#{SecureRandom.hex(4)}")
    git!("clone", repo.to_s, scratch.to_s)
    git!("-c", "user.name=someone", "-c", "user.email=someone@example.com", "commit", "--allow-empty", "-m", "Unrelated change", chdir: scratch)
    git!("push", "origin", "main", chdir: scratch)
  end

  # A PR-mode env on a project whose config repo is `repo`.
  def pr_connection_for(repo, path:, select_tags:)
    project = FactoryBot.create(:project, git_repo: repo.to_s, git_branch: "main")
    env = FactoryBot.create(:project_env, project: project, name: "uat", apply_mode: "pr", source: "registry",
      git_path: path, select_tags: select_tags)
    FactoryBot.create(:kong_connection, project_env: env)
  end

  private

  def git!(*args, chdir: @bare_git_tmp)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: chdir.to_s)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end
