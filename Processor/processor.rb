#!/usr/bin/env ruby

require 'bunny'
require 'mongo'
require 'json'

### Start thread to read messages off the bus and act accordingly.
bunny = Bunny.new
bunny.start
@channel = bunny.create_channel
queue = @channel.queue("#{ENV['FAZ_QUEUE_NAME']}_received")

@mongo = Mongo::Client.new('mongodb://127.0.0.1:27017/fazool')
@collection = @mongo[:quotes]

@routing_key = "send_to_#{ENV['FAZ_QUEUE_NAME']}"

COMMANDS = { 
  'help'            => "Display this help text",
  'who <text>'      => 'Who dunnit?',
  'what <text>'     => "Arbitrary questions around 'what' i.e. 'What gives?'",
  'what time is it' => "Self explanatory",
  'how <text>'      => "How questions: How is the sky blue?",
  'why <text>'      => "Why questions",
  'will <text>'     => "Will Jerry go to the dance?",
  'recall <text>'   => "recall lol",
  'recall when <author> said <text>'  => "recall when Joey said hello",
  '<text>ometer'    => "Faz, what does the funnyometer say?",
  'stats' =>  "Reports simple stats",
  'fortune' => "Returns a BSD fortune",
  'store' => "Store phrase to be recalled"
}


def push_message(text)
  @channel.default_exchange.publish(text, :routing_key => @routing_key)
end


def help_command(prefix)
  COMMANDS.each do |k,v|
    push_message("#{prefix} #{k} > #{v}")
  end
end

def recall_command(prefix, command, actor, with_count=false)
  query = { quote: nil }
  id_str = ""
  id_match = /(with id)$/.match(command)
  if id_match
    id_str = id_match[1]
    command.gsub!(/ with id$/, '')
  end

  output_match = /(with output)$/.match(command)
  if output_match
    prefix = ":>>"
    command.gsub!(/ with output$/, '')
  end

  author = nil
  base_command = /^(.*?) /.match(command)[1]
  if command =~ /recall when / 
    # Need to get by user.
    author, regex = /recall when (.*?) said (.*?)$/.match(command)[1,2]
    author.strip!
    regex.strip!
  elsif command =~ /count when/
    author, regex = /count when (.*?) said (.*?)$/.match(command)[1,2]
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
    query[:author] = author if author
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
      push_message("#{prefix} #{quote['created_at']}: #{id_str} #{quote['quote']}")
    end
  else
    # Found nothing.
    push_message("#{prefix} Sorry, I find no matching entries.")
  end
end


def who_command(prefix)
  distinct_count = @collection.distinct('author').count
  culprit = @collection.distinct('author').sample
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
    'If a frog had wings, would it bump its ass a hoppin?',
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
  author_count = @collection.distinct('author').count
  push_message("#{prefix} There are currently #{count} entries in my database from #{author_count} different authors.")
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
  when /^[wW]ill/
    will_command(prefix)
  when /ometer/
    meter_command(prefix)
  when 'stats'
    stats_command(prefix)
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
      actor = body.split(' ').shift
      if request
        command_logic(request, is_page, actor)
      end
    else
      # Record this to the database.
      if body !~ /^##/ and body !~ /^You / and body !~ /^Fazool /
        if body =~ /^[a-zA-Z0-9]/
          actor = body.split(' ').shift
          actor = /^[a-zA-Z0-9]+/.match(actor)[0]
          @collection.insert_one({author: actor, quote: body, :created_at => Time.now})
          if body =~ /https?:/
            url = body.match(/(http.*?)[ "]/)[0].to_s
            url.gsub!(/"$/, '')
            key = ENV['FAZ_SHORTENER_KEY']
            shortened = `curl https://www.googleapis.com/urlshortener/v1/url\?key=#{key} -H 'Content-Type: application/json' -d '{"longUrl": "#{url}"}' 2>/dev/null`
            url_json = JSON.parse(shortened)
            push_message("say #{url_json['id']}")
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





