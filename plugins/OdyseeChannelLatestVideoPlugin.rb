require_relative 'Plugin'
require 'time'

# Fetch the latest video claim from one or more Odysee channels via Odysee's
# public LBRY API proxy (resolve + claim_search), rather than channel RSS.
# Accepts an Odysee handle such as "@BehindTheVeil33" or a channel URL.
class OdyseeChannelLatestVideoPlugin < Plugin
  API_URL = 'https://api.na-backend.odysee.com/api/v1/proxy'.freeze
  EMPTY = {
    'title' => '', 'url' => '', 'video_id' => '',
    'thumbnail' => '', 'published' => '', 'channel' => ''
  }.freeze

  def execute
    args.each_with_object({}) do |input, output|
      channel = normalize_channel_input(input)
      result = cache("odysee-latest-api:#{input}") { fetch_latest(channel) } || EMPTY.dup
      # Safe fallback only when the API is unavailable. The configured link
      # key remains the original input, e.g. @BehindTheVeil33.
      result = result.merge('url' => channel_page_url(channel)) if result['url'].to_s.empty? && channel
      output[input] = result
    end
  end

  private

  def fetch_latest(channel)
    return nil unless channel

    resolved = api_call('resolve', 'urls' => ["lbry://#{channel}"])
    channel_claim = find_claim(resolved)
    unless channel_claim
      log("could not resolve channel #{channel.inspect} through Odysee API")
      return nil
    end

    channel_id = channel_claim['claim_id'].to_s
    return nil if channel_id.empty?

    search = api_call(
      'claim_search',
      'channel_ids' => [channel_id],
      'claim_type' => ['stream'],
      'stream_types' => ['video'],
      'has_source' => true,
      'page' => 1,
      'page_size' => 1,
      'order_by' => ['release_time']
    )
    video = find_first_video(search)
    unless video
      log("no video claims returned for #{channel.inspect}")
      return nil
    end

    value = video['value'].is_a?(Hash) ? video['value'] : {}
    signing_channel = video['signing_channel'].is_a?(Hash) ? video['signing_channel'] : channel_claim
    title = value['title'] || video['title'] || video['name'] || ''
    url = video_url(video, signing_channel, channel_claim)
    return nil if url.empty?

    thumbnail = nested_value(value, 'thumbnail', 'url') ||
      nested_value(video, 'thumbnail', 'url') || value['thumbnail'] || ''
    timestamp = video['timestamp'] || video['release_time'] || video.dig('meta', 'release_time')

    {
      'title' => title.to_s,
      'url' => url,
      'video_id' => video['claim_id'].to_s,
      'thumbnail' => thumbnail.to_s,
      'published' => normalize_date(timestamp),
      'channel' => (signing_channel['name'] || channel_claim['name'] || channel).to_s
    }
  rescue StandardError => e
    log("latest-video lookup for #{channel.inspect} failed: #{e.class}: #{e.message}")
    nil
  end

  def api_call(method, params)
    response = http_post_json(
      API_URL,
      payload: { 'method' => method, 'params' => params },
      default: nil,
      timeout: 20
    )
    return nil unless response.is_a?(Hash)
    if response['error']
      log("Odysee API #{method} error: #{response['error']}")
      return nil
    end

    response['result'] || response['data'] || response
  end

  def find_claim(data)
    return nil unless data.is_a?(Hash)
    return data if data['claim_id']

    data.each_value do |value|
      found = find_claim(value)
      return found if found && (found['value_type'].to_s == 'channel' || found['claim_type'].to_s == 'channel' || found['name'].to_s.start_with?('@'))
    end
    nil
  end

  def find_first_video(data)
    return nil unless data.is_a?(Hash)
    items = data['items']
    return items.find { |item| item.is_a?(Hash) } if items.is_a?(Array)

    data.each_value do |value|
      found = find_first_video(value)
      return found if found
    end
    nil
  end

  def video_url(video, signing_channel, channel_claim)
    %w[short_url canonical_url permanent_url].each do |key|
      url = normalize_claim_url(video[key])
      return url unless url.empty?
    end

    name = video['name'].to_s
    claim_id = video['claim_id'].to_s
    channel_name = signing_channel['name'] || channel_claim['name']
    channel_id = signing_channel['claim_id'] || channel_claim['claim_id']
    return '' if name.empty? || claim_id.empty? || channel_name.to_s.empty?

    channel_part = channel_name.to_s.start_with?('@') ? channel_name.to_s : "@#{channel_name}"
    channel_part += ":#{channel_id}" unless channel_id.to_s.empty?
    "https://odysee.com/#{channel_part}/#{name}:#{claim_id}"
  end

  def normalize_claim_url(raw)
    value = raw.to_s.strip
    return '' if value.empty?

    if value.start_with?('lbry://')
      value = "https://odysee.com/#{value.delete_prefix('lbry://').tr('#', ':')}"
    elsif value.start_with?('http://', 'https://')
      # Accept only Odysee links from API metadata.
      uri = URI.parse(value)
      return '' unless %w[odysee.com www.odysee.com].include?(uri.host)
      return uri.to_s
    else
      return ''
    end

    value
  rescue URI::InvalidURIError
    ''
  end

  def nested_value(hash, *keys)
    keys.reduce(hash) do |value, key|
      value.is_a?(Hash) ? value[key] : nil
    end
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
    value = "@#{value}" unless value.start_with?('@')
    value
  rescue URI::InvalidURIError
    nil
  end

  def channel_page_url(channel)
    "https://odysee.com/#{channel}"
  end

  def normalize_date(raw)
    return '' if raw.to_s.empty?

    Time.at(raw.to_f).utc.strftime('%Y-%m-%d') if raw.to_s.match?(/\A\d+(?:\.\d+)?\z/)
    Time.parse(raw.to_s).strftime('%Y-%m-%d') unless raw.to_s.match?(/\A\d+(?:\.\d+)?\z/)
  rescue ArgumentError, RangeError
    raw.to_s[0, 10]
  end
end
