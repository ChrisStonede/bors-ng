defmodule BorsNG.GitHub.FriendlyMock do
  @moduledoc """
  Helper functions for ServerMock for common operations without having to
  modify state by hand.

  Tries to lookup values instead of requiring full %{} associative arrays.

  Assumes a single GitHub instance with a single repository and single user.

  Does everything through webhook notifications. Does not use
  Database.Repo.insert directly! (One exception: adding a reviewer,
  which is normally done through Bors' web UI.)
  """

  alias BorsNG.GitHub.ServerMock
  alias BorsNG.GitHub.FriendlyMock
  alias BorsNG.GitHub.Pr
  alias BorsNG.WebhookController

  alias BorsNG.Database
  alias BorsNG.Database.Repo

  # Defaults
  @def_user %{"id" => 7,
	      "login" => "tester",
	      "avatar_url" => "" }
  @def_inst 91
  @def_repo 14
  @def_files %{".github/bors.toml" => ~s"""
    status = [ "ci" ]
    pr_status = [ "ci" ]
    prerun_timeout_sec = 5
    delete_merged_branches = true
    """}
  
  def init_state() do
    # Creates a single installation with a single repo where
    # nothing has happened yet.
    # Will do everything through webhook notifications.
    ServerMock.put_state(%{
      {:installation, 91} => %{ repos: [
          %BorsNG.GitHub.Repo{
	    id: @def_repo,
	    name: "test/repo",
	    owner: %{type: :user,
		     id: @def_user["id"],
		     login: @def_user["login"],
		     avatar_url: @def_user["avatar_url"]}}
      ] },
      {{:installation, @def_inst}, @def_repo} => %{
        branches: %{"master" => "ini"},
        commits: %{},
        comments: %{},
        statuses: %{},
        files: %{"master" => @def_files,
		 "staging.tmp" => @def_files},
	collaborators: %{},
	pulls: %{},
	pr_commits: %{}
      }})
    # Notify Bors and sync.
    WebhookController.do_webhook(%{
	  body_params: %{
	    "installation" => %{ "id" => @def_inst },
	    "sender" => @def_user,
	    "action" => "created" }}, "github", "installation")
    BorsNG.Worker.SyncerInstallation.wait_hot_spin_xref(@def_inst)
  end

  def prs(repo \\ @def_repo, inst \\ @def_inst) do
    # How can I get both open and unopen PRs?
    BorsNG.GitHub.get_open_prs!({{:installation, inst}, repo})
  end

  def comments(repo \\ @def_repo, inst \\ @def_inst) do
    conn = {{:installation, inst}, repo}
    state = ServerMock.get_state
    with({:ok, repo} <- Map.fetch(state, conn),
         {:ok, comments} <- Map.fetch(repo, :comments),
      do: comments)
  end

  def add_pr(title, body \\ nil) do
    # branch name == title for now
    # This function could be expanded later to be more parametrizable.
    number = 1 + Enum.max([0 | Enum.map(prs(), fn x -> x.number end)])
    sha = "SHA-#{number}"
    ref = title
    pr = %Pr{number: number,
	     title: title,
	     state: :open,
	     base_ref: "master",
	     head_sha: sha,
	     head_ref: ref,
	     body: body,
	     user: @def_user}
    update_mock([:pulls], &(Map.put(&1, number, pr)))
    update_mock([:pr_commits], &(Map.put(&1, number, [])))
    update_mock([:comments], &(Map.put(&1, number, [])))
    update_mock([:branches], &(Map.put(&1, ref, sha)))
    update_mock([:files], &(Map.put(&1, sha, @def_files)))
    update_mock([:statuses], &(Map.put(&1, sha, %{})))
    WebhookController.do_webhook(%{
    	  body_params: %{
    	    "installation" => %{ "id" => @def_inst },
    	    "sender" => @def_user,
	    "repository" => %{ "id" => @def_repo},
    	    "pull_request" => pr_to_json(pr),
    	    "action" => "created" }},
          "github", "pull_request")
    number
  end

  def update_mock(path, fun, repo \\ @def_repo, inst \\ @def_inst) do
    path = [{{:installation, inst}, repo} | path]
    ServerMock.put_state(update_in(ServerMock.get_state, path, fun))
  end

  def commits(pr_num, repo \\ @def_repo, inst \\ @def_inst) do
    BorsNG.GitHub.get_pr_commits!({{:installation, inst}, repo}, pr_num)
  end

  def add_commit(pr_num, sha, author) do
    commit = %{sha: sha,
	       author_name: author,
	       author_email: author <> "'s email"}
    # Could eventually prepend instead of appending to make things faster
    update_mock([:pr_commits, pr_num], &(&1 ++ [commit]))
  end

  def add_comment(pr_num, body, author \\ @def_user) do
    # Adds a reviewer comment.
    pr = Enum.find(prs(), &(match?(%{number: ^pr_num}, &1)))
    update_mock([:comments, pr_num], &([body | &1]))
    WebhookController.do_webhook(%{
	  body_params: %{
	    "sender" => author,
    	    "repository" => %{ "id" => @def_repo},
	    "comment" => %{ "user" => author,
			    "body" => body },
	    "pull_request" => pr_to_json(pr),
	    "action" => "created" }} , "github", "pull_request_review_comment")
  end

  def make_admin(username \\ @def_user["login"]) do
    user = Database.Repo.get_by! Database.User, login: username
    Database.Repo.update! Database.User.changeset(user, %{is_admin: true})
  end


  def add_reviewer(repo \\ @def_repo, user \\ @def_user) do
    # Could try to replace this with calls to the phoenix server
    # to avoid the direct call to BorsNG.ProjectController
    project = Repo.get_by!(Database.Project, %{repo_xref: repo})
    BorsNG.ProjectController.add_reviewer(nil, :rw, project, %{"reviewer" => user})
  end

  def ci_status(hash, ci_name, status) do
    # Set CI status
    update_mock([:statuses, hash], &(Map.put(&1, ci_name, status)))
  end

  def full_example() do
    alias BorsNG.GitHub.FriendlyMock
    FriendlyMock.init_state
    FriendlyMock.make_admin
    pr_num = FriendlyMock.add_pr "first"
    FriendlyMock.add_reviewer
    # "ci" comes from the line pr_status = [ "ci" ] in bors.toml
    FriendlyMock.ci_status("SHA-1", "ci", :running)
    FriendlyMock.add_comment(pr_num, "bors ping")
    FriendlyMock.add_comment(pr_num, "bors r+")
    #FriendlyMock.ci_status("SHA-1", "ci", :ok)
  end

  def pr_to_json(%Pr{number: number,
		     title: title,
		     state: state,
		     base_ref: base_ref,
		     head_sha: head_sha,
		     body: body,
		     user: user}) do
    %{
    "number" => number,
    "title" => title,
    "body" => body,
    "state" => Atom.to_string(state),
    "base" => %{
      "ref" => base_ref,
      "repo" => %{
        "id" => 0 #base_repo_id
      }
    },
    "head" => %{
      "sha" => head_sha,
      "ref" => "0000",
      "repo" => %{
        "id" => "0"
      }
    },
    "user" => user,
    "merged_at" => "some non-nul time :)",
    }
  end
end
