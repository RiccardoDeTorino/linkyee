require_relative 'Plugin'
require 'time'
require 'uri'

# Fetch the latest video for one or more Odysee channels.
# Accepts a handle, URL, or plain slug, and resolves the public Odysee API.
#
# Example:
#   plugins:
#     - OdyseeChannelLatestVideoPlugin:
#         - "@my-channel"
#         - "https://odysee.com/@my-channel"
#
# Output (Hash<input, Hash>):
#   {
#     "@my-channel" => {
#       "title" => "Latest title",
#       "url" => "https://odysee.com/...",
#       "video_id" => "...",
#       "thumbnail" => "https://...",
#       "published" => "2026-05-01",
#       "channel" => "My Channel"
#     }
#   }
class OdyseeChannelLatestVideoPlugin < Plugin
  API_URL = 'https://api.na-backend.odysee.com/api/v1/proxy'.freeze

  EMPTY = {
    'title' => nil, 'url' => nil, 'video_id' => nil,
    'thumbnail' => nil, 'published' => nil, 'channel' => nil
  }.freeze

  def execute
    args.each_with_object({}) do |input, out|
      out[input] = cache("odysee-latest:#{input}") { load_latest(input) } || EMPTY.dup
    end
  end

  private

  def load_latest(input)
    channel = normalize_channel_input(input)
    return nil unless channel

    resolved = post_json({
      'method' => 'resolve',
      'params' => { 'urls' => ["lbry://#{channel}"] }
    })
    claim = extract_channel_claim(resolved)
    return nil unless claim

    channel_id = claim['claim_id'].to_s
    return nil if channel_id.empty?

    search = post_json({
      'method' => 'claim_search',
      'params' => {
        'channel_ids' => [channel_id],
        'claim_type' => ['stream'],
        'stream_types' => ['video'],
        'has_source' => true,
        'page' => 1,
        'page_size' => 1,
        'order_by' => ['release_time']
      }
    })

    video = extract_first_claim(search)
    return nil unless video

    value = video['value'].is_a?(Hash) ? video['value'] : {}
    url = normalize_video_url(video['canonical_url'] || video['permanent_url'] || video['short_url'])
    title = (value['title'] || video['title'] || video['name']).to_s.strip
    channel_name = (claim['name'] || claim['value']&.[]('title') || channel).to_s

    {
      'title' => title.empty? ? nil : title,
      'url' => url.empty? ? fallback_video_url(video, channel_name) : url,
      'video_id' => (video['claim_id'] || value['video_id'] || '').to_s.strip.empty? ? nil : (video['claim_id'] || value['video_id'] || '').to_s.strip,
      'thumbnail' => (thumb = thumbnail_url(value, video)).empty? ? nil : thumb,
      'published' => normalize_date(video['timestamp'] || video['release_time']),
      'channel' => channel_name.sub(%r{\A@}, '').empty? ? nil : channel_name.sub(%r{\A@}, '')
    }
  rescue StandardError => e
    log("Odysee lookup failed: #{e.class}: #{e.message}")
    nil
  end

  def post_json(payload)
    uri = URI(API_URL)
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json'
    req['Origin'] = 'https://odysee.com'
    req['Referer'] = 'https://odysee.com/'
    req.body = JSON.generate(payload)

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 20, read_timeout: 20) do |http|
      http.request(req)
    end
    return nil unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  rescue StandardError => e
    log("Odysee POST request failed: #{e.class}: #{e.message}")
    nil
  end

  def extract_channel_claim(data)
    return nil unless data.is_a?(Hash)

    if data['claim_id'].to_s != '' && data['value_type'].to_s == 'channel'
      return data
    end

    if data.key?('result') && data['result'].is_a?(Hash)
      found = extract_channel_claim(data['result'])
      return found if found
    end

    data.each_value do |value|
      next unless value.is_a?(Hash)
      found = extract_channel_claim(value)
      return found if found
    end

    nil
  end

  def extract_first_claim(data)
    return nil unless data.is_a?(Hash)

    if data.key?('result')
      found = extract_first_claim(data['result'])
      return found if found
    end

    items = data['items']
    if items.is_a?(Array)
      item = items.find { |entry| entry.is_a?(Hash) }
      return item if item
    end

    data.each_value do |value|
      next unless value.is_a?(Hash)
      found = extract_first_claim(value)
      return found if found
    end

    nil
  end

  def normalize_video_url(value)
    url = value.to_s.strip
    return nil if url.empty?

    if url.start_with?('lbry://')
      url.sub!(%r{\A(lbry://)}, '')
      url = "https://odysee.com/#{url.tr('#', ':')}"
    elsif url.start_with?('http://', 'https://')
      uri = URI.parse(url)
      return nil unless %w[odysee.com www.odysee.com].include?(uri.host)
    else
      return nil
    end

    url
  rescue URI::InvalidURIError
    nil
  end

  def fallback_video_url(video, channel_name)
    name = video['name'].to_s.strip
    claim_id = video['claim_id'].to_s.strip
    channel = channel_name.to_s.strip
    return nil if name.empty? || claim_id.empty? || channel.empty?

    channel = "@#{channel}" unless channel.start_with?('@')
    "https://odysee.com/#{channel}/#{name}:#{claim_id}"
  end

  def thumbnail_url(value, video)
    thumb = value['thumbnail'] || video['thumbnail']
    return nil unless thumb
    return thumb['url'].to_s.strip.empty? ? nil : thumb['url'].to_s if thumb.is_a?(Hash)
    thumb.to_s.strip.empty? ? nil : thumb.to_s
  end

  def normalize_channel_input(input)
    value = input.to_s.strip
    return nil if value.empty?

    if value.start_with?('http://', 'https://')
      uri = URI.parse(value)
      return nil unless %w[odysee.com www.odysee.com].include?(uri.host)
      value = uri.path.to_s.sub(%r{\A/+}, '')
    end

    value = value.sub(%r{\A/+}, '').sub(%r{/+\z}, '')
    return nil if value.empty?

    value = "@#{value}" unless value.start_with?('@')
    value
  rescue URI::InvalidURIError
    nil
  end

  def normalize_date(raw)
    return nil if raw.to_s.empty?
    return Time.at(raw.to_f).utc.strftime('%Y-%m-%d') if raw.to_s.match?(/\A\d+(?:\.\d+)?\z/)

    Time.parse(raw.to_s).strftime('%Y-%m-%d')
  rescue ArgumentError, RangeError
    raw.to_s[0, 10]
  end
end
