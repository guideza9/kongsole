require "rails_helper"
require "open3"
require "tmpdir"

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
end
