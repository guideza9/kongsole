require "rails_helper"
require "open3"
require "tmpdir"
require Rails.root.join("spec/support/bare_git_repo")

RSpec.describe Kong::GitClient do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = Pathname.new(dir)
      example.run
    end
  end

  def sh!(*cmd, chdir:)
    _out, err, status = Open3.capture3(*cmd, chdir: chdir.to_s)
    raise "#{cmd.join(' ')} failed: #{err}" unless status.success?
  end

  let(:bare_repo) { @tmp.join("origin.git") }

  before do
    sh!("git", "init", "--bare", "--initial-branch=main", bare_repo.to_s, chdir: @tmp)

    scratch = @tmp.join("seed")
    sh!("git", "clone", bare_repo.to_s, scratch.to_s, chdir: @tmp)
    File.write(scratch.join("kong.yaml"), "services: []\n")
    sh!("git", "add", "-A", chdir: scratch)
    sh!("git", "-c", "user.name=seed", "-c", "user.email=seed@example.com", "commit", "-m", "seed", chdir: scratch)
    sh!("git", "push", "origin", "main", chdir: scratch)
  end

  let(:connection) do
    create(:kong_connection, git_repo: bare_repo.to_s, git_branch: "main", git_path: "kong.yaml")
  end

  def client_for(connection)
    described_class.new(connection: connection, working_dir: @tmp.join("cache"))
  end

  it "clones on the first pull, then fetches+resets on later pulls" do
    git = client_for(connection)

    git.pull!
    expect(File.read(git.working_dir.join("kong.yaml"))).to eq("services: []\n")

    # Someone else pushes to origin between pulls.
    other_clone = @tmp.join("other")
    sh!("git", "clone", bare_repo.to_s, other_clone.to_s, chdir: @tmp)
    File.write(other_clone.join("kong.yaml"), "services: [{name: x}]\n")
    sh!("git", "add", "-A", chdir: other_clone)
    sh!("git", "-c", "user.name=other", "-c", "user.email=other@example.com", "commit", "-m", "update", chdir: other_clone)
    sh!("git", "push", "origin", "main", chdir: other_clone)

    git.pull!
    expect(File.read(git.working_dir.join("kong.yaml"))).to eq("services: [{name: x}]\n")
  end

  it "checks out a branch, writes a file, commits, and pushes it without touching main" do
    git = client_for(connection).pull!

    git.checkout_branch!("kongctl/1")
    git.write_file("kong.yaml", "services: [{name: payments-api}]\n")
    sha = git.commit!("create payments-api", author_name: "alice")
    git.push!("kongctl/1")

    expect(sha).to match(/\A[0-9a-f]{40}\z/)

    stdout, = Open3.capture3("git", "branch", "-a", chdir: bare_repo.to_s)
    expect(stdout).to include("kongctl/1")

    main_stdout, = Open3.capture3("git", "show", "main:kong.yaml", chdir: bare_repo.to_s)
    expect(main_stdout).to eq("services: []\n")
  end

  it "raises Kong::GitClient::Error with the git failure message when a command fails" do
    connection.git_repo = @tmp.join("does-not-exist.git").to_s

    expect { client_for(connection).pull! }.to raise_error(Kong::GitClient::Error)
  end
  # R8.4: the changeset preview reads the whole working copy's diff, the
  # remote's head, and always leaves the working copy clean.
  describe "for a changeset" do
    include BareGitRepo

    let(:repo) { bare_git_repo(path: "uat/kong.yaml", select_tags: %w[t]) }
    let(:connection) { pr_connection_for(repo, path: "uat/kong.yaml", select_tags: %w[t]) }

    it "diffs a rewritten file against the base, then discards it" do
      git = described_class.new(connection: connection).pull!
      git.write_file("uat/kong.yaml", "_format_version: \"3.0\"\nservices: []\n")
      expect(git.diff("uat/kong.yaml")).to include("+services: []")
      git.discard!
      status, = Open3.capture3("git", "status", "--porcelain", chdir: git.working_dir.to_s)
      expect(status).to be_empty
    end

    it "shows a file that did not exist yet as all added" do
      git = described_class.new(connection: connection).pull!
      git.write_file("uat/new.yaml", "x: 1\n")
      expect(git.diff("uat/new.yaml")).to include("+x: 1")
    end

    it "reads the remote branch's head without a working copy" do
      expect(described_class.new(connection: connection).remote_head_sha).to eq(head_sha(repo))
    end
  end

  it "tells an unreachable git host apart from a refused key" do
    connection = create(:kong_connection, project_env: create(:project_env, apply_mode: "pr", source: "registry",
      project: create(:project, git_repo: "https://git.example/team/repo.git")))
    failed = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture3)
      .and_return([ "", "fatal: unable to access 'https://git.example/team/repo.git/': Could not resolve host: git.example", failed ])
    expect { described_class.new(connection: connection, working_dir: Pathname(Dir.mktmpdir)).pull! }
      .to raise_error(described_class::Unreachable) { |e| expect(e.kind).to eq(:dns) }

    allow(Open3).to receive(:capture3).and_return([ "", "git@git.example: Permission denied (publickey).", failed ])
    expect { described_class.new(connection: connection, working_dir: Pathname(Dir.mktmpdir)).pull! }
      .to raise_error(described_class::AuthFailed)
  end
  # Final review #9: a git host that never answers (a VPN that is off drops
  # packets) is given up on, as unreachable, instead of hanging the request.
  it "gives up on a git command that does not finish in time" do
    connection = create(:kong_connection, project_env: create(:project_env, apply_mode: "pr", source: "registry",
      project: create(:project, git_repo: "https://git.example/team/repo.git")))
    client = described_class.new(connection: connection, working_dir: Pathname(Dir.mktmpdir))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { client.send(:run!, RbConfig.ruby, "-e", "sleep 10", chdir: Dir.tmpdir, timeout: 0.5) }
      .to raise_error(described_class::Unreachable) { |e| expect(e.kind).to eq(:timeout) }
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end
end
