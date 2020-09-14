#!/usr/bin/env ruby

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'bunny'
require 'mongo'
require 'json'
require 'net/http'
require 'crack/xml'

### Start thread to read messages off the bus and act accordingly.
bunny = Bunny.new
bunny.start
@channel = bunny.create_channel
queue = @channel.queue("#{ENV['FAZ_QUEUE_NAME']}_received")

@mongo = Mongo::Client.new('mongodb://127.0.0.1:27017/fazool')
@collection = @mongo[:quotes]

@routing_key = "send_to_#{ENV['FAZ_QUEUE_NAME']}"

COMMANDS = {
  'help'               => "Display this help text",
  'weather <location>' => 'Check weather',
  'who <text>'         => 'Who dunnit?',
  'what <text>'        => "Arbitrary questions around 'what' i.e. 'What gives?'",
  'what time is it'    => "Self explanatory",
  'how <text>'         => "How questions: How is the sky blue?",
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

# def covid_command(prefix, region, location='https://opendata.arcgis.com/datasets/1cb306b5331945548745a5ccd290188e_1.geojson', limit=10)
def covid_command(prefix, region, location='https://prod-hub-indexer.s3.amazonaws.com/files/1cb306b5331945548745a5ccd290188e/1/full/4326/1cb306b5331945548745a5ccd290188e_1_full_4326.geojson', limit=10)
  if region and region =~ /^usa$/i
    region.upcase!
    # location = 'https://opendata.arcgis.com/datasets/628578697fb24d8ea4c32fa0c5ae1843_0.geojson'
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
  recovery_count = 0 
   puts " REGION: '#{region}'"
  if region != '' and region != 'USA'
    region_data = parsed['features'].select{|x| x['properties']['Province_State'] =~ /#{region}/i}
    if region_data.count == 0 # try Country Region
      region_data = parsed['features'].select{|x| x['properties']['Country_Region'] =~ /#{region}/i}
    end
    region_data.map{|x| death_count += x['properties']['Deaths']}
    region_data.map{|x| recovery_count += x['properties']['Recovered']}
    region_data.map{|x| case_count += x['properties']['Confirmed']}
  else
    parsed['features'].map{|x| death_count += x['properties']['Deaths']}
    parsed['features'].map{|x| case_count += x['properties']['Confirmed']}
    parsed['features'].map{|x| recovery_count += x['properties']['Recovered']}
  end 
  death_count = death_count.to_s.reverse.scan(/.{1,3}/).join(',').reverse
  case_count = case_count.to_s.reverse.scan(/.{1,3}/).join(',').reverse
  recovery_count = recovery_count.to_s.reverse.scan(/.{1,3}/).join(',').reverse
  push_message("#{prefix} COVID19 #{region == '' ?  "World" : region.capitalize} - Dth: #{death_count}, Case: #{case_count}, Rcvr: #{recovery_count} (#{Time.now.to_s.split(" ")[0..1].join(' ')[0..15]})")
end


def news_command(prefix)
  key = ENV['FAZ_SHORTENER_KEY']
  shortener_login = ENV['FAZ_SHORTENER_LOGIN']
  body = Net::HTTP.get('feeds.skynews.com', '/feeds/rss/world.xml')
  parsed = Crack::XML.parse(body)
  items = parsed["rss"]["channel"]["item"]
  items.each do |item|
    title = item["title"].strip
    title = title.sub(/<a.+?>/, '').sub('</a>', '')
    link = item["link"].strip
    shortened = `curl 'http://api.bitly.com/v3/shorten\?login=#{shortener_login}&apiKey=#{key}&longUrl=#{link}&version=2.0.1' 2>/dev/null`
    resp = JSON.parse(shortened)
    push_message("#{prefix} #{resp['data']['url']} - #{title}")
  end
end


def weather_command(prefix, locale)
  locale.chomp!
  puts "Locale requested: #{locale}"
  # sed 's/\x1b\[[0-9;]*m//g'
  weather = `curl -B http://wttr.in/#{locale}?T 2>/dev/null | head -7`
  puts " Weather response: #{weather}"
  push_message("#{prefix} : #{weather}")
  weather.split("\n").each do |x|
    push_message("#{prefix} : #{x.gsub(' ', '%b').gsub('B0', '').gsub(/\\/, '%\\')}")
  end
end

def recall_command(prefix, command, actor, with_count=false)
  query = { quote: nil }
  id_str = ""
  id_match = /( with id)(?:$|\r|\n)/.match(command)
  puts " id_match: #{id_match}"
  puts " command: #{command}"
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
  puts " RESULT ARRAY: #{result_array}"
      result_array.sort{|a,b| b[1] <=> a[1]}.each do |x|
puts " X: #{x}"
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
  puts "  QUOTE: #{quote.inspect}"

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


def who_command(prefix)
  culprit_id = @collection.distinct('author_id').sample
  culprit = @collection.find({author_id: culprit_id}).first['author']
  phrase_array = [
    'It was probably',
    "I'm guessing",
    "Wouldn't bet on it, but I've got 5 dollars on",
    ' ',
    'Your mother told me it was',
    "Don't you think it might've been",
    "Smells like",
    "Could be"
  ]
  push_message("#{prefix} #{phrase_array.sample} #{culprit}")
end


def will_command(prefix)
  phrase_array = [
    'Sources say, "No"',
    'Yes, definitely.',
    'Probably not.',
    'Yes.',
    'No.',
    'Affirmative.',
    "I don't know, but unicorns ROCK!",
    'Surely.',
    'Negative, ghost rider.',
    'Not on your life',
    'If a frog had wings, would it bump its ass a hoppin?',
    "In the words of 60 of Bill Cosby's friends, 'No.'",
    "I wouldn't bet on it.",
    'Most assuredly.',
    'Maybe after tea.',
    'How should I know?',
    'Ask Baga. I think he bought it.',
    'Probably.',
    "If the good lord willin' and the creek don't rise",
    "If the good lord willin' and the creek don't dry up",
    "Yeah right after someone admits to receding.",
    'Right after Blood gives up drugs.'
  ]
  push_message("#{prefix} #{phrase_array.sample}")
end


def how_command(prefix)
  phrase_array = [
    'By osmosis.',
    'By removing his head from his.. hey, whoah, I just saw a trail.',
    'North by northweset.',
    "By visiting your grandma's place.",
    "Elementary, Watson.", 'How should I know?', 
    'I have no idea.', 
    'Just follow the instructions.', 
    'Let me google that for you.',
    'Let me Bing that for ya...'
  ]
  push_message("#{prefix} #{phrase_array.sample}")
end

def when_command(prefix, actor)
  count = @collection.find(:quote => /"[wW]hen /).count
  random = @collection.find(:quote => /"[wW]hen /).limit(-1).skip(rand(count)).first
  if random
    push_message("#{prefix} #{/"(.*?)"/.match(random['quote'])[1]}")
  else 
    push_message("#{prefix} I'm sorry. I have no answer for that, #{actor}")
  end
end

def what_command(prefix, command, actor)
  if command =~ /time is/
    push_message("#{prefix} It is currently #{Time.now}, #{actor}")
  elsif command =~ /the fuck/i
    push_message("#{prefix} I bet you expect me to say 'Indeed.' but I'm not your stupid Slack bot.")
  else
    count = @collection.find(:quote => /"[iI]t /).count()
    random = @collection.find(:quote => /"[iI]t /).limit(-1).skip(rand(count)).first
    # thing = random_quote['quote'].split(' ').sample.gsub('"', '')
    # phrase_array = [ 'My best guess is', 'How about..', 'Your sister would say', "I'm thinking" ]
    # push_message("#{prefix} #{phrase_array.sample} '#{thing}', #{actor}")
    if random
      push_message("#{prefix} #{/"(.*?)"/.match(random['quote'])[1]}")
    else 
      push_message("#{prefix} I'm sorry. I have no answer for that, #{actor}")
    end
  end
end


def why_command(prefix, actor)
  count = @collection.find(:quote => /"[bB]ecause/).count
  random = @collection.find(:quote => /"[bB]ecause/).limit(-1).skip(rand(count)).first
  if random
    push_message("#{prefix} #{/"(.*?)"/.match(random['quote'])[1]}")
  else 
    push_message("#{prefix} I'm sorry. I have no answer for that, #{actor}")
  end
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
  when /^[wW]ho/
    # Who based command. Make shit up.
    who_command(prefix)
  when /^[wW]hat/
    what_command(prefix, command, actor)
  when /^[hH]ow/
    how_command(prefix)
  when /^[wW]hy/
    why_command(prefix, actor)
  when /^[wW]hen/
    when_command(prefix, actor)
  when /^[aA]re/
    will_command(prefix)
  when /^[iI]s/
    will_command(prefix)
  when /^[wW]ill/
    will_command(prefix)
  when /^[sS]hould/
    will_command(prefix)
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
    push_message("#{prefix} Sorry, #{actor} but I do not understand that command.")
  end
end


begin
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
      actor = /^\[(.*?)\(/.match(body)[1]
      if request
        command_logic(request, is_page, actor)
      end
    else
      # Record this to the database.
      if body !~ /^##/ and body !~ /^You / and body !~ /^Fazool /
        if body =~ /^\[[a-zA-Z0-9]/
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
              key = ENV['FAZ_SHORTENER_KEY']
              shortener_login = ENV['FAZ_SHORTENER_LOGIN']
              shortened = `curl 'http://api.bitly.com/v3/shorten\?login=#{shortener_login}&apiKey=#{key}&longUrl=#{url}&version=2.0.1' 2>/dev/null`
              resp = JSON.parse(shortened)
              push_message("say #{resp['data']['url']}")
            end
          end
        end
      end
    end
  end
rescue Interrupt => e
  puts " Error: #{e}"
  bunny.close
  exit(1)
end





