require 'spec_helper'

describe Api::Endpoints::TeamsEndpoint do
  include Api::Test::EndpointTest

  it_behaves_like 'a cursor api', Team

  context 'team' do
    let(:existing_team) { Fabricate(:team) }

    it 'returns a team' do
      team = client.team(id: existing_team.id)
      expect(team.id).to eq existing_team.id.to_s
      expect(team._links.self._url).to eq "http://example.org/api/teams/#{existing_team.id}"
    end
  end

  context 'teams' do
    context 'active/inactive' do
      let!(:active_team) { Fabricate(:team, active: true) }
      let!(:inactive_team) { Fabricate(:team, active: false) }

      it 'returns all teams' do
        teams = client.teams
        expect(teams.count).to eq 2
      end

      it 'returns active teams' do
        teams = client.teams(active: true)
        expect(teams.count).to eq 1
        expect(teams.to_a.first.team_id).to eq active_team.team_id
      end
    end

    context 'api true/false' do
      let!(:team_on) { Fabricate(:team, api: true) }
      let!(:team_off) { Fabricate(:team, api: false) }

      it 'returns teams with api on only' do
        teams = client.teams
        expect(teams.count).to eq 1
      end
    end
  end

  context 'team' do
    let(:existing_team) { Fabricate(:team) }

    it 'returns a team' do
      team = client.team(id: existing_team.id)
      expect(team.id).to eq existing_team.id.to_s
    end

    it 'requires code' do
      expect { client.teams._post }.to raise_error Faraday::ClientError do |e|
        json = JSON.parse(e.response[:body])
        expect(json['message']).to eq 'Invalid parameters.'
        expect(json['type']).to eq 'param_error'
      end
    end

    context 'register' do
      before do
        oauth_access = {
          'bot' => {
            'bot_access_token' => 'token',
            'bot_user_id' => 'bot_user_id'
          },
          'access_token' => 'access_token',
          'user_id' => 'activated_user_id',
          'team_id' => 'team_id',
          'team_name' => 'team_name'
        }
        ENV['SLACK_CLIENT_ID'] = 'client_id'
        ENV['SLACK_CLIENT_SECRET'] = 'client_secret'
        allow_any_instance_of(Slack::Web::Client).to receive(:oauth_access).with(
          hash_including(
            code: 'code',
            client_id: 'client_id',
            client_secret: 'client_secret'
          )
        ).and_return(oauth_access)
      end

      after do
        ENV.delete('SLACK_CLIENT_ID')
        ENV.delete('SLACK_CLIENT_SECRET')
      end

      it 'creates a team' do
        expect(SlackRubyBotServer::Service.instance).to receive(:start!)
        expect do
          team = client.teams._post(code: 'code')
          expect(team.team_id).to eq 'team_id'
          expect(team.name).to eq 'team_name'
          team = Team.find(team.id)
          expect(team.token).to eq 'token'
        end.to change(Team, :count).by(1)
      end

      it 'reactivates a deactivated team' do
        expect(SlackRubyBotServer::Service.instance).to receive(:start!)
        existing_team = Fabricate(:team, token: 'token', active: false)
        expect do
          team = client.teams._post(code: 'code')
          expect(team.team_id).to eq existing_team.team_id
          expect(team.name).to eq existing_team.name
          expect(team.active).to be true
          team = Team.find(team.id)
          expect(team.token).to eq 'token'
          expect(team.active).to be true
        end.not_to change(Team, :count)
      end

      it 'returns a useful error when team already exists' do
        existing_team = Fabricate(:team, token: 'token')
        expect { client.teams._post(code: 'code') }.to raise_error Faraday::ClientError do |e|
          json = JSON.parse(e.response[:body])
          expect(json['message']).to eq "Team #{existing_team.name} is already registered."
        end
      end

      it 'reactivates a deactivated team with a different code' do
        expect(SlackRubyBotServer::Service.instance).to receive(:start!)
        existing_team = Fabricate(:team, token: 'old', team_id: 'team_id', active: false)
        expect do
          team = client.teams._post(code: 'code')
          expect(team.team_id).to eq existing_team.team_id
          expect(team.name).to eq existing_team.name
          expect(team.active).to be true
          team = Team.find(team.id)
          expect(team.token).to eq 'token'
          expect(team.active).to be true
        end.not_to change(Team, :count)
      end

      context 'with mailchimp settings' do
        before do
          SlackRubyBotServer::Mailchimp.configure do |config|
            config.mailchimp_api_key = 'api-key'
            config.mailchimp_list_id = 'list-id'
          end
        end

        after do
          SlackRubyBotServer::Mailchimp.config.reset!
          ENV.delete('MAILCHIMP_API_KEY')
          ENV.delete('MAILCHIMP_LIST_ID')
          ENV.delete('MAILCHIMP_API_KEY')
          ENV.delete('MAILCHIMP_LIST_ID')
        end

        let(:list) { double(Mailchimp::List, members: double(Mailchimp::List::Members)) }

        it 'subscribes to the mailing list' do
          expect(SlackRubyBotServer::Service.instance).to receive(:start!)

          allow_any_instance_of(Slack::Web::Client).to receive(:users_info).with(
            user: 'activated_user_id'
          ).and_return(
            user: {
              profile: {
                email: 'user@example.com',
                first_name: 'First',
                last_name: 'Last'
              }
            }
          )

          allow_any_instance_of(Mailchimp::Client).to receive(:lists).with('list-id').and_return(list)

          expect(list.members).to receive(:where).with(email_address: 'user@example.com').and_return([])

          expect(list.members).to receive(:create_or_update).with(
            email_address: 'user@example.com',
            merge_fields: {
              'FNAME' => 'First',
              'LNAME' => 'Last',
              'BOT' => 'SlackApiExplorer'
            },
            status: 'pending',
            name: nil,
            tags: %w[slack-api-explorer],
            unique_email_id: 'team_id-activated_user_id'
          )

          client.teams._post(code: 'code')
        end
      end
    end
  end
end
