require_relative 'Plugin'
require 'nokogiri'
require 'time'

# Fetch the latest items from one or more RSS / Atom feeds.
# Works with Medium, blogs, podcasts, YouTube channels, etc.
#
# List style (each entry is a feed URL, default limit = 5):
#   plugins:
#     - RSSFeedPlugin:
#         - https://blog.zhgchg.li/feed
#         - https://medium.com/feed/ztravel
#
# Output (Hash<String, Array<Hash>>):
#   {
#     "https://blog.zhgchg.li/feed" => [
#       { "title" => "...", "url" => "...", "date" => "2026-05-01" },
#       ...
#     ]
#   }
#
# Use in Liquid:
#   {% for item in vars.RSSFeedPlugin['https://blog.zhgchg.li/feed'] %}
#     {{ item.title }} — {{ item.date }}
#   {% endfor %}
# plugins/RSSFeedPlugin.rb
class RSSFeedPlugin < Plugin
  DEFAULT_LIMIT = 5

  def execute
    args.each_with_object({}) do |url, out|
      out[url] = cache("rss:#{url}") { load_feed(url, DEFAULT_LIMIT) } || []
    end
  end

  private

  def load_feed(url, limit)
    res = http_get(url)
    unless res.is_a?(Net::HTTPSuccess)
      warn "[RSSFeedPlugin] Feed fetch failed for #{url}: #{res&.code} #{res&.message}"
      return nil
    end

    body = res.body.to_s
    body = body.force_encoding("UTF-8")
    body = body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�") if body.valid_encoding?

    doc = Nokogiri::XML(body) do |config|
      config.noent.noblanks
    end

    items = doc.xpath('//item | //entry')
    items.first(limit).map { |node| parse_item(node) }
  rescue StandardError => e
    warn "[RSSFeedPlugin] parse failed for #{url}: #{e.class}: #{e.message}"
    warn e.backtrace.first(10).join("\n")
    nil
  end
end

  def parse_item(node)
    title = (node.at_xpath('title') || node.at_xpath('xmlns:title'))&.text.to_s.strip

    link_node =
      node.at_xpath('link[@rel="alternate"]') ||
      node.at_xpath('xmlns:link[@rel="alternate"]') ||
      node.at_xpath('link[@href]') ||
      node.at_xpath('xmlns:link[@href]') ||
      node.at_xpath('link') ||
      node.at_xpath('xmlns:link')

    link = link_node&.[]('href') || link_node&.text.to_s.strip

    # Substack sometimes exposes the site root as the generic link; ignore that
    # and let config fallback handle it if we cannot find a real article URL.
    if link == 'https://riccardodetorino.substack.com/' || link == 'https://riccardodetorino.substack.com'
      link = ''
    end

    raw_date = (
      node.at_xpath('pubDate') ||
      node.at_xpath('xmlns:updated') ||
      node.at_xpath('xmlns:published')
    )&.text.to_s.strip

    {
      'title' => title,
      'url' => link,
      'date' => normalize_date(raw_date)
    }
  end

  def normalize_date(raw)
    return '' if raw.empty?
    Time.parse(raw).strftime('%Y-%m-%d')
  rescue ArgumentError
    raw[0, 10]
  end
end
