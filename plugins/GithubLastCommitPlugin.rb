require_relative 'Plugin'
require 'nokogiri'

# Fetch the most recent commit info for one or more GitHub repos.
#
#   plugins:
#     - GithubLastCommitPlugin:
#         - ZhgChgLi/linkyee
#
# Output (Hash<String, Hash>):
#   {
#     "ZhgChgLi/linkyee" => {
#       "sha" => "7d7392d2",
#       "date" => "2026-05-07",
#       "message" => "Add AI Style Designer skill, ..."
#     }
#   }
#
# Use in Liquid:
#   Last commit: {{ vars.GithubLastCommitPlugin['ZhgChgLi/linkyee'].date }}
class GithubLastCommitPlugin < Plugin
  def execute
    args.each_with_object({}) do |repo, out|
      out[repo] = cache("gh-last-commit:#{repo}") { load_last_commit(repo) } ||
                  { 'sha' => nil, 'date' => nil, 'message' => nil }
    end
  end

  private

  def load_last_commit(repo)
    # Use the public commits feed (Atom) — no auth, no rate limit.
    res = http_get("https://github.com/#{repo}/commits.atom")
    return nil unless res.is_a?(Net::HTTPSuccess)

    doc = Nokogiri::XML(res.body)
    entry = doc.at_xpath('//xmlns:entry')
    return nil unless entry

    sha_raw = entry.at_xpath('xmlns:id')&.text.to_s
    date_raw = entry.at_xpath('xmlns:updated')&.text.to_s
    title_raw = entry.at_xpath('xmlns:title')&.text.to_s

    {
      'sha' => sha_raw.empty? ? nil : sha_raw.split('/').last[0, 7],
      'date' => date_raw.empty? ? nil : date_raw[0, 10],
      'message' => title_raw.strip.empty? ? nil : title_raw.strip
    }
  end
end
