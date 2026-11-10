require_relative 'Plugin'
require 'nokogiri'
require 'time'
require 'uri'

# Fetch the latest items from one or more RSS / Atom feeds.
# Works with Medium, blogs, podcasts, YouTube channels, etc.
#
# List style (each entry is a feed URL, default limit = 5):
#   plugins:
#     - RSSFeedPlugin:
#         - https://blog.example/feed
#
# Output (Hash<String, Array<Hash>>):
#   { "https://blog.example/feed" => [{ "title" => "...", "url" => "...", "date" => "2026-05-01" }] }
class RSSFeedPlugin < Plugin
  DEFAULT_LIMIT = 5
  FEED_HEADERS = {
    'Accept' => 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
    # Some hosted feeds, including Substack, may reject generic script clients.
    'User-Agent' => 'Mozilla/5.0 (compatible; linkyee RSS reader; +https://github.com/ZhgChgLi/linkyee)'
  }.freeze

  def execute
    args.each_with_object({}) do |url, out|
      out[url] = cache("rss:#{url}") { load_feed(url, DEFAULT_LIMIT) } || []
    end
  end

  private

  def load_feed(url, limit)
    res = http_get(url, headers: FEED_HEADERS)
    unless res.is_a?(Net::HTTPSuccess)
      warn "[RSSFeedPlugin] Feed fetch failed for #{url}: #{res&.code} #{res&.message}"
      return nil
    end

    body = res.body.to_s.force_encoding('UTF-8')
    body = body.encode('UTF-8', invalid: :replace, undef: :replace, replace: "\uFFFD")

    doc = Nokogiri::XML(body) do |config|
      config.nonet
      config.noblanks
    end

    items = doc.xpath('//*[local-name()="item" or local-name()="entry"]')
    if items.empty?
      detail = doc.errors.map(&:message).join('; ')
      content_type = res['content-type'].to_s
      warn "[RSSFeedPlugin] No RSS items or Atom entries found in #{url} (content-type: #{content_type})#{": #{detail}" unless detail.empty?}"
      return nil
    end

    items.first(limit).map { |node| parse_item(node) }
  rescue StandardError => e
    warn "[RSSFeedPlugin] parse failed for #{url}: #{e.class}: #{e.message}"
    warn e.backtrace.first(10).join("\n")
    nil
  end

  def parse_item(node)
    title = child_text(node, 'title')

    # RSS uses link text; Atom uses link href. Prefer an alternate/article link,
    # then try the permalink GUID used by some feeds (including Substack).
    links = node.xpath('./*[local-name()="link"]')
    preferred_links = links.sort_by do |link_node|
      link_node['rel'].to_s == 'alternate' ? 0 : (link_node['href'] || '').empty? ? 1 : 2
    end
    link = preferred_links.map do |link_node|
      href = link_node['href'].to_s.strip
      href.empty? ? link_node.text.to_s.strip : href
    end.find { |candidate| usable_article_url?(candidate) }

    if link.nil?
      guid = node.at_xpath('./*[local-name()="guid"]')
      candidate = guid&.text.to_s.strip
      link = candidate if usable_article_url?(candidate) && guid&.[]('isPermaLink') != 'false'
    end

    raw_date = child_text(node, 'pubDate')
    raw_date = child_text(node, 'updated') if raw_date.empty?
    raw_date = child_text(node, 'published') if raw_date.empty?

    {
      'title' => title.empty? ? nil : title,
      'url' => link.nil? ? nil : link.to_s.strip.empty? ? nil : link.to_s,
      'date' => normalize_date(raw_date)
    }
  end

  def child_text(node, name)
    node.at_xpath("./*[local-name()=#{name.to_json}]")&.text.to_s.strip
  end

  def usable_article_url?(candidate)
    return false if candidate.to_s.empty?

    uri = URI.parse(candidate)
    return false unless %w[http https].include?(uri.scheme) && uri.host

    # Avoid treating a publication homepage as a post permalink.
    !(uri.path.to_s.empty? || uri.path == '/')
  rescue URI::InvalidURIError
    false
  end

  def normalize_date(raw)
    return nil if raw.empty?

    Time.parse(raw).strftime('%Y-%m-%d')
  rescue ArgumentError
    raw[0, 10]
  end
end
