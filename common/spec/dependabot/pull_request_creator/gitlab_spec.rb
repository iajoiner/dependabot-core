# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/pull_request_creator/gitlab"

RSpec.describe Dependabot::PullRequestCreator::Gitlab do
  subject(:creator) do
    described_class.new(
      source: source,
      branch_name: branch_name,
      base_commit: base_commit,
      credentials: credentials,
      files: files,
      commit_message: commit_message,
      pr_description: pr_description,
      pr_name: pr_name,
      author_details: author_details,
      labeler: labeler,
      approvers: approvers,
      assignee: assignee,
      milestone: milestone
    )
  end

  let(:source) do
    Dependabot::Source.new(provider: "gitlab", repo: "gocardless/bump")
  end
  let(:branch_name) { "dependabot/bundler/business-1.5.0" }
  let(:base_commit) { "basecommitsha" }
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "gitlab.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end
  let(:files) { [gemfile, gemfile_lock] }
  let(:commit_message) { "Commit msg" }
  let(:pr_description) { "PR msg" }
  let(:pr_name) { "PR name" }
  let(:author_details) { nil }
  let(:approvers) { nil }
  let(:assignee) { nil }
  let(:milestone) { nil }
  let(:labeler) do
    Dependabot::PullRequestCreator::Labeler.new(
      source: source,
      credentials: credentials,
      custom_labels: custom_labels,
      includes_security_fixes: false,
      dependencies: [dependency],
      label_language: false
    )
  end
  let(:custom_labels) { nil }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: "business",
      version: "1.5.0",
      previous_version: "1.4.0",
      package_manager: "bundler",
      requirements: [],
      previous_requirements: []
    )
  end

  let(:gemfile) do
    Dependabot::DependencyFile.new(
      name: "Gemfile",
      content: fixture("ruby", "gemfiles", "Gemfile")
    )
  end
  let(:gemfile_lock) do
    Dependabot::DependencyFile.new(
      name: "Gemfile.lock",
      content: fixture("ruby", "gemfiles", "Gemfile")
    )
  end

  let(:json_header) { { "Content-Type" => "application/json" } }
  let(:repo_api_url) do
    "https://gitlab.com/api/v4/projects/#{CGI.escape(source.repo)}"
  end

  before do
    stub_request(:get, repo_api_url).
      to_return(status: 200,
                body: fixture("gitlab", "bump_repo.json"),
                headers: json_header)
    stub_request(
      :get,
      "#{repo_api_url}/repository/branches/#{CGI.escape(branch_name)}"
    ).to_return(
      status: 404,
      body: fixture("gitlab", "branch_not_found.json"),
      headers: json_header
    )
    stub_request(:post, "#{repo_api_url}/repository/branches").
      with(query: { branch: branch_name, ref: base_commit }).
      to_return(status: 200,
                body: fixture("gitlab", "branch.json"),
                headers: json_header)
    stub_request(:post, "#{repo_api_url}/repository/commits").
      to_return(status: 200,
                body: fixture("gitlab", "create_commit.json"),
                headers: json_header)
    stub_request(:get, "#{repo_api_url}/labels").
      to_return(status: 200,
                body: fixture("gitlab", "labels_with_dependencies.json"),
                headers: json_header)
    stub_request(:post, "#{repo_api_url}/merge_requests").
      to_return(status: 200,
                body: fixture("gitlab", "merge_request.json"),
                headers: json_header)
  end

  describe "#create" do
    it "pushes a commit to GitLab and creates a merge request" do
      creator.create

      expect(WebMock).
        to have_requested(:post, "#{repo_api_url}/repository/commits")
      expect(WebMock).
        to have_requested(:post, "#{repo_api_url}/merge_requests")
    end

    context "with a submodule" do
      let(:files) do
        [
          Dependabot::DependencyFile.new(
            name: "manifesto",
            type: "submodule",
            content: "sha1"
          )
        ]
      end

      before do
        stub_request(:put, "#{repo_api_url}/repository/submodules/manifesto").
          to_return(status: 200,
                    body: fixture("gitlab", "create_commit.json"),
                    headers: json_header)
      end

      it "pushes a commit to GitLab and creates a merge request" do
        creator.create

        expect(WebMock).
          to have_requested(
            :put, "#{repo_api_url}/repository/submodules/manifesto"
          ).with(
            body: hash_including(
              branch: branch_name,
              commit_sha: "sha1",
              commit_message: commit_message
            )
          )
        expect(WebMock).
          to have_requested(:post, "#{repo_api_url}/merge_requests")
      end
    end

    context "when the branch already exists" do
      before do
        stub_request(
          :get,
          "#{repo_api_url}/repository/branches/#{CGI.escape(branch_name)}"
        ).to_return(
          status: 200,
          body: fixture("gitlab", "branch.json"),
          headers: json_header
        )
      end

      context "but a merge request to this branch doesn't" do
        before do
          stub_request(:get, "#{repo_api_url}/merge_requests").
            with(
              query: {
                source_branch: branch_name,
                target_branch: "master",
                state: "all"
              }
            ).to_return(status: 200, body: "[]", headers: json_header)
        end

        context "and the commit doesn't already exists on that branch" do
          before do
            stub_request(:get, "#{repo_api_url}/repository/commits").
              with(query: { ref_name: branch_name }).
              to_return(status: 200,
                        body: fixture("gitlab", "commits.json"),
                        headers: json_header)
          end

          it "creates a commit and merge request with the right details" do
            expect(creator.create).to_not be_nil

            expect(WebMock).
              to have_requested(:post, "#{repo_api_url}/repository/commits")
            expect(WebMock).
              to have_requested(:post, "#{repo_api_url}/merge_requests")
          end
        end

        context "and a commit already exists on that branch" do
          before do
            stub_request(:get, "#{repo_api_url}/repository/commits").
              with(query: { ref_name: branch_name }).
              to_return(status: 200,
                        body: fixture("gitlab", "commits_with_existing.json"),
                        headers: json_header)
          end

          it "creates a merge request but not a commit" do
            expect(creator.create).to_not be_nil

            expect(WebMock).
              to_not have_requested(:post, "#{repo_api_url}/repository/commits")
            expect(WebMock).
              to have_requested(:post, "#{repo_api_url}/merge_requests")
          end
        end
      end

      context "and a merge request to this branch already exists" do
        before do
          stub_request(:get, "#{repo_api_url}/merge_requests").
            with(
              query: {
                source_branch: branch_name,
                target_branch: "master",
                state: "all"
              }
            ).to_return(status: 200, body: "[{}]", headers: json_header)
        end

        it "doesn't create a commit or merge request (and returns nil)" do
          expect(creator.create).to be_nil

          expect(WebMock).
            to_not have_requested(:post, "#{repo_api_url}/repository/commits")
          expect(WebMock).
            to_not have_requested(:post, "#{repo_api_url}/merge_requests")
        end
      end
    end

    context "when a approvers has been requested" do
      let(:approvers) { { "approvers" => [1_394_555] } }
      before do
        stub_request(:put, "#{repo_api_url}/merge_requests/5/approvers").
          to_return(
            status: 200,
            body: fixture("gitlab", "merge_request.json"),
            headers: json_header
          )
      end

      it "adds the approvers to the MR correctly" do
        creator.create

        expect(WebMock).
          to have_requested(:put, "#{repo_api_url}/merge_requests/5/approvers")
      end
    end
  end
end