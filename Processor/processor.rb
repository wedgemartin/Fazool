#!/usr/bin/env ruby

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'bunny'
require 'mongo'
require 'json'
require 'net/http'
require 'crack/xml'
require 'ruby/openai'
require 'base64'

require 'httparty'
HTTParty::Basement.default_options.update(verify: false)

# HTTParty.get("#{@settings.api_ssl_server}#{url1}")
# HTTParty.get("#{@settings.api_ssl_server}#{url2}")
# HTTParty.get("#{@settings.api_ssl_server}#{url3}")



@openai_key = ENV['FAZ_OPENAI_KEY']
@shortener_url = 'https://ugov.co/u/urls'
@shortener_login = ENV['FAZ_SHORTENER_LOGIN']

### Start thread to read messages off the bus and act accordingly.
COMMANDS = {
  'help'               => "Display this help text",
  'weather <location>' => 'Check weather',
  'who <text>'         => 'Who dunnit?',
  'what <text>'        => "Arbitrary questions around 'what' i.e. 'What gives?'",
  'what time is it'    => "Self explanatory",
  'how <adjective> are we?' => 'Current US covid summaries',
  'how <text>'         => "How questions: How is the sky blue?",
  'tell me <text>'     => "Tell me why it rains?",
  'why <text>'         => "Why questions",
  'when <text>'        => "When questions i.e. when will i get married?",
  'will <text>'        => "Will Jerry go to the dance?",
  'should <text>'      => "Should I play the lottery?",
  'recall <text>'      => "recall lol",
  'recall when <author> said <text>'  => "recall when Joey said hello",
  'recall when [everybody|everyone] said <text>'        => "counts how many times each author has said <text>",
  '<text>ometer'       => "Faz, what does the funnyometer say?",
  'stats'              =>  "Reports simple stats",
  'authors'            =>  "Reports author list with IDs",
  'fortune'            => "Returns a BSD fortune",
  'store'              => "Store phrase to be recalled",
  'robinhood'          => "Check status of Robinhood",
  'market'             => "Check status of stock market"
}


def push_message(text)
  @channel.default_exchange.publish(text, :routing_key => @routing_key)
end


def help_command(prefix)
  COMMANDS.each do |k,v|
    push_message("#{prefix} #{k} > #{v}")
  end
end

def robinhood_command(prefix)
  response = Net::HTTP.get_response(URI('https://status.robinhood.com'))
  if response.body =~ /span.*utage/
    push_message("#{prefix} Robinhood is currently having an outage.")
  elsif response.body =~ /span.*egraded/
    push_message("#{prefix} Robinhood system is degraded.")
  else
    push_message("#{prefix} Robinhood is operational")
  end
end

def covid_command(prefix, region, location='https://prod-hub-indexer.s3.amazonaws.com/files/1cb306b5331945548745a5ccd290188e/1/full/4326/1cb306b5331945548745a5ccd290188e_1_full_4326.geojson', limit=10)
  if region and region =~ /^usa$/i
    region.upcase!
    location = 'https://prod-hub-indexer.s3.amazonaws.com/files/628578697fb24d8ea4c32fa0c5ae1843/0/full/4326/628578697fb24d8ea4c32fa0c5ae1843_0_full_4326.geojson'
  end
  url = URI.parse(location)
  req = Net::HTTP::Get.new(url.path, {'User-Agent' => 'Mozilla/5.0'})
  res = Net::HTTP.start(url.hostname, url.port, use_ssl: true) {|http|
    http.request(req)
  }
  case res
  when Net::HTTPSuccess     then res
  when Net::HTTPRedirection then covid_command(res['location'], limit - 1)
  else
    response.error!
  end
  parsed = JSON.parse(res.body)
  death_count = 0
  case_count = 0
  active_count = 0
  recovery_count = 0
  if region != '' and region != 'USA'
    region_data = parsed['features'].select{|x| x['properties']['Province_State'] =~ /#{region}/i}
    if region_data.count == 0 # try Country Region
      region_data = parsed['features'].select{|x| x['properties']['Country_Region'] =~ /#{region}/i}
    end
    region_data.map{|x| death_count += x['properties']['Deaths'] || 0}
    region_data.map{|x| recovery_count += x['properties']['Recovered'] || 0}
    region_data.map{|x| active_count += x['properties']['Active'] || 0}
    region_data.map{|x| case_count += x['properties']['Confirmed'] || 0}
  else
    parsed['features'].map{|x| death_count += x['properties']['Deaths'] || 0}
    parsed['features'].map{|x| case_count += x['properties']['Confirmed'] || 0}
    parsed['features'].map{|x| active_count += x['properties']['Active'] || 0}
    parsed['features'].map{|x| recovery_count += x['properties']['Recovered'] || 0}
  end
  death_count = death_count.to_s.reverse.scan(/.{1,3}/).join(',').reverse
  case_count = case_count.to_s.reverse.scan(/.{1,3}/).join(',').reverse
  active_count = active_count.to_s.reverse.scan(/.{1,3}/).join(',').reverse
  recovery_count = recovery_count.to_s.reverse.scan(/.{1,3}/).join(',').reverse
  push_message("#{prefix} COVID19 #{region == '' ?  "World" : region.capitalize} - Active: #{active_count},  Dth: #{death_count}, Case: #{case_count}, Rcvr: #{recovery_count} (#{Time.now.to_s.split(" ")[0..1].join(' ')[0..15]})")
  parsed[:created_at] = Time.now
  parsed[:region] = region
  @covid_collection.insert_one(parsed)
end


def news_command(prefix)
  # key = ENV['FAZ_SHORTENER_KEY']
  news_uri = URI('https://feeds.skynews.com/feeds/rss/world.xml')
  body = Net::HTTP.get(news_uri)
puts " BODY: #{body}"
  parsed = Crack::XML.parse(body)
puts " PARSED: #{parsed}"
  items = parsed["rss"]["channel"]["item"]
puts " ITEMS: #{items}"
  items.each do |item|
    title = item["title"].strip
    title = title.sub(/<a.+?>/, '').sub('</a>', '')
    link = item["link"].strip
    shortened = `curl -X POST -d 'url=#{link}' '#{@shortener_url}' 2>/dev/null`
    resp = JSON.parse(shortened)
    puts " SHORTENED: #{shortened}"
    push_message("#{prefix} #{resp['url']} - #{title}")
  end
end


def weather_command(prefix, locale)
  locale.chomp!
  weather = `curl -B http://wttr.in/#{locale}?T 2>/dev/null | head -7`
  push_message("#{prefix} : #{weather}")
  weather.split("\n").each do |x|
    push_message("#{prefix} : #{x.gsub(' ', '%b').gsub('B0', '').gsub(/\\/, '%\\')}")
  end
end

def recall_command(prefix, command, actor, with_count=false)
  query = { quote: nil }
  id_str = ""
  id_match = /( with id)(?:$|\r|\n)/.match(command)
  if id_match
    id_str = id_match[1]
    command.gsub!(/ with id(?:$|\r|\n)/, '')
  end

  output_match = /( with output)(?:$|\r|\n)/.match(command)
  if output_match
    prefix = ":>>"
    command.gsub!(/ with output(?:$|\r|\n)/, '')
  end

  author = nil
  base_command = /^(.*?) /.match(command)[1]
  if command =~ / posed /
    query['is_pose'] = true
  end
  if command =~ /recall when every/
    # Get list of unique authors.
    author_ids = @collection.distinct('author_id').to_a
    phrase = /recall when every.* said (.*)$/.match(command)[1]
    result_array = []
    author_ids.each do |x|
      author_count = @collection.count(author_id: x, quote: /#{phrase}/)
      if author_count > 0
        author = @collection.find(author_id: x).limit(1).first
        result_array.push([ "#{author['author']} said #{phrase} #{author_count} times", author_count ])
        # push_message("#{prefix} #{author['author']} said #{phrase} #{author_count} times")
      end
    end
    if result_array.count > 0
      result_array.sort{|a,b| b[1] <=> a[1]}.each do |x|
        push_message("#{prefix} #{x[0]}")
      end
    else
      push_message("#{prefix} Ain't nobody said that.")
    end
    return
  elsif command =~ /recall when /
    # Need to get by user.
    author, regex = /recall when (.*?) (?:said|posed) (.*?)$/.match(command)[1,2]
    author.strip!
    regex.strip!
  elsif command =~ /count when/
    author, regex = /count when (.*?) (?:said|posed) (.*?)$/.match(command)[1,2]
    author.strip!
    regex.strip!
  elsif command =~ /^count /
    regex = /^count (.*?)$/.match(command)[1].strip
  elsif command =~ /recall id /
    _id = /recall id (.*?)$/.match(command)[1].strip
    query = { _id: BSON::ObjectId(_id) }
  else
    regex = /recall (.*?)$/.match(command)[1].strip
  end

  unless _id
    query[:quote] = /#{regex}/i
    atmp = @collection.find(author: author, quote: {"$ne": nil}).first
    if atmp
      author_id = atmp['author_id']
    end
    if author_id
      query[:author_id] = author_id
    else
      query[:author] = author if author
    end
  end
  query_count = @collection.find(query).count
  quote = ''
  unless with_count
    # Don't need to make the find query if we just want a count.
    quote = @collection.find(query).limit(-1).skip(rand(query_count)).first
  end

  if quote or with_count
    if id_str.length > 1
      id_str = quote['_id']
    end
    if with_count
      if command =~ /when (.*?) said/
        push_message("#{prefix} #{author} said '#{regex}' exactly #{query_count} times.")
      else
        push_message("#{prefix} '#{regex}' appears #{query_count} times.")
      end
    else
      push_message("#{prefix} #{quote['created_at']}: #{quote['forced_by'] ? "<force by #{quote['forced_by']}>" : '' } #{id_str} #{quote['quote']}")
    end
  else
    # Found nothing.
    push_message("#{prefix} Sorry, I find no matching entries.")
  end
end

def ai_command(prefix, command=nil)
  # tellme = command.gsub('tell me ', '')
  client = OpenAI::Client.new(access_token: @openai_key)
  # client.models.retrieve(id: 'text-davinci-001')
  model = 'text-ada-001'
  if command =~ /^davinci/
    command = command.gsub('davinci', '')
    model = 'text-davinci-001'
  end
  data = client.completions(parameters: {
    prompt: command,
    temperature: 0,
    max_tokens: 1800,
    model: model,
  })
  # data = client.completions(
    # parameters: {
      # model: 'text-davinci-003',
      # prompt: tellme,
      # max_tokens: 5
    # }
  # )
  puts " RAW DATA: #{data.inspect}"
  response = data['choices'].first['text'].strip
  response.gsub!(/[\r\n]+/, ' ')
  response
  puts " RESPONSE IS: #{response}"
  # phrase_array = [
    # 'By osmosis.',
    # 'By removing his head from his.. hey, whoah, I just saw a trail.',
    # 'North by northweset.',
    # "By visiting your grandma's place.",
    # "Elementary, Watson.", 'How should I know?',
    # 'I have no idea.',
    # 'Just follow the instructions.',
    # 'Let me google that for you.',
    # 'Let me Bing that for ya...'
  # ]
  # response = phrase_array.sample
  push_message("#{prefix} #{response}")
end

def stats_command(prefix)
  count = @collection.count()
  author_count = @collection.distinct('author_id').count
  push_message("#{prefix} There are currently #{count} entries in my database from #{author_count} different authors.")
end

def authors_command(prefix)
  count = @collection.count()
  authors = @collection.distinct('author_id').to_a
  author_array = []
  authors.each do |x|
    author = @collection.find(author_id: x).limit(1).first
    author_array.push("#{author['author']}(##{x})")
  end
  push_message("#{prefix} #{author_array.join(", ")}")
end

def fortune_command(prefix)
  fortune = `fortune`
  fortune.gsub!(/[\r\n]+/m, ' ')
  fortune.gsub!('  ', ' ')
  fortune.gsub!(/\t+/, ' ')
  push_message("#{prefix} #{fortune}")
end

def store_command(prefix, string, actor)
  string.gsub!(/^store /, '')
  @collection.insert_one({author: actor, quote: "#{actor} stored: #{string}", :created_at => Time.now})
  push_message("#{prefix} Stored.")
end

def meter_command(prefix)
  dec = rand()
  num = rand(100)
  push_message("#{prefix} #{num + dec}")
end

def command_logic(command, page_bool, actor)
  puts "  ACTOR HERE IS: #{actor}"
  prefix = page_bool ? "page #{actor} = : >>" : ":>>"
  base_command = ''
  if command =~ /^[sS]tats/
    base_command = 'stats'
  elsif command =~ /^[fF]ortune/
    base_command = 'fortune'
  else
    # base_command = /^(.*?)[ "]/.match(command)[1]
    if command =~ / /
      base_command = /^(.*?) /.match(command)
    else
      base_command = /^(\w+)/.match(command)
    end
    if base_command
      base_command = base_command[1]
    else
      base_command = command
    end
  end

  case base_command
  when 'help'
    help_command(prefix)
  when 'weather'
    weather_command(prefix, command.split(' ')[1])
  when 'news'
    news_command(prefix)
  when 'robinhood'
    robinhood_command(prefix)
  when 'covid'
    covid_command(prefix, command.split(' ')[1..9].join(' '))
  when 'recall'
    recall_command(prefix, command, actor)
  when /^[cC]ount/
    recall_command(prefix, command, actor, true)
  when /ometer/
    meter_command(prefix)
  when 'stats'
    stats_command(prefix)
  when 'authors'
    authors_command(prefix)
  when 'fortune'
    fortune_command(prefix)
  when 'store'
    store_command(prefix, command, actor)
  else
    ai_command(prefix, command)
  end
end

def main_loop
  begin
    bunny = Bunny.new
    bunny.start
    @channel = bunny.create_channel
    queue = @channel.queue("#{ENV['FAZ_QUEUE_NAME']}_received")

    # @mongo = Mongo::Client.new('mongodb://127.0.0.1:27017/fazool')
    @mongo = Mongo::Client.new([ '127.0.0.1:27017' ],
                               user: 'fazool',
                               password: ENV['FAZ_PASS'],
                               database: 'fazool' )

    @collection = @mongo[:quotes]
    @covid_collection = @mongo[:covid]
    @routing_key = "send_to_#{ENV['FAZ_QUEUE_NAME']}"

    puts "Subscribing to queue '#{ENV['FAZ_QUEUE_NAME']}-received'..."
    queue.subscribe(:block => true) do |delivery_info, properties, body|
      puts " Got body from bus: #{body}"
      # Body will either be a request for data recall
      #   or stuff that needs to be filtered/recorded in the DB
      if body =~ /"Faz(...)?,/ or body =~ / to you\./ or body =~ / pages: /
        # We have a command.
        page_type = "MUCK"
        if body =~ / to you\./
          is_page = true
        elsif body =~ / pages: /
          is_page = true
          page_type = "MUSH"
        end
        request = nil
          if is_page
          if page_type == "MUCK"
            request = /"(.*?)"/.match(body)[1]
            else
            request = /pages: (.*?)$/.match(body)[1]
          end
        else
          request = /"Faz(?:...)?, (.*?)"/.match(body)[1]
        end
        actor = /^\[?(.*?)\(?/.match(body)[1]
        if request
          command_logic(request, is_page, actor)
          end
      else
        # Record this to the database.
        if body !~ /^##/ and body !~ /^You / and body !~ /^Fazool /
          if body =~ /^\[?[a-zA-Z0-9]/
            real_body = body.match(/^\[.*?\](.*)/).captures[0]
            actor = body.split(' ').shift
            if actor.match(/^\[[a-zA-Z0-9]+\(#(\d+)\)/)
              author_id = actor.match(/^\[[a-zA-Z0-9]+\(#(\d+)\)/).captures[0]
              if actor =~ /<-/ # this is a force.
                # look up author_id
                forced_by_id = actor.match(/<-\(#(\d+)\)/).captures[0]
                forced_by = @collection.find(author_id: forced_by_id, quote: {"$ne": nil}).first['author']
              end
              actor = actor.match(/^\[([a-zA-Z0-9]+)\(/).captures[0]
              data = {author_id: author_id, author: actor, quote: real_body, created_at: Time.now, forced_by: forced_by, is_pose: false}
              if body =~ /saypose/
                data[:is_pose] = true
              end
              @collection.insert_one(data)
              if real_body =~ /https?:/
                url = real_body.match(/(http.*?)[ "]/)[0].to_s
                url.gsub!(/"$/, '')
                payload = "url=#{Base64.encode64(url).gsub(/\n/, '')}"
                shortened = HTTParty.post(@shortener_url, body: payload)
                # resp = JSON.parse(shortened)
                push_message("say #{shortened['url']}")
              end
            end
          end
        end
      end
    end
  rescue => e
    Rails.logger.info "Handling error: #{e}"
    Rails.logger.info "Reentering main loop..."
    sleep 1
    main_loop
  end
end

main_loop
