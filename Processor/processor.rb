#!/usr/bin/env ruby

require 'bunny'
require 'mongo'

### Start thread to read messages off the bus and act accordingly.
bunny = Bunny.new
bunny.start
channel = bunny.create_channel
queue = channel.queue('del_received')

@mongo = Mongo::Client.new('mongodb://127.0.0.1:27017/fazool')
@collection = @mongo[:quotes]

@routing_key = "send_to_del"


def recall_logic(channel, command, page_bool, actor)
  query = { quote: nil }
  if command =~ /regex/
    regex = /regex (.*?)"/.match(command)[1]
  elsif command =~ /recall when/
    # Need to get by user.
    author, regex = /recall when (.*?) said (.*?)"/.match(command)[1,2]
  else
    regex = /recall (.*?)"/.match(command)[1]
  end

  query[:quote] = /#{regex}/
  query[:author] = author if author
  random = @collection.find(query).count
  quote = @collection.find(query).limit(-1).skip(rand(random)).first

  prefix = page_bool ? "page #{actor} = : >>" : ":>>"

  if quote
    channel.default_exchange.publish("#{prefix} #{quote['created_at']}: #{quote['quote']}", :routing_key => @routing_key)
  else
    # Found nothing.
    channel.default_exchange.publish("#{prefix} Sorry, I find no matching entries.", :routing_key => @routing_key)
  end

end

begin
  puts "Subscribing to queue 'del-received'..."
  queue.subscribe(:block => true) do |delivery_info, properties, body|
    puts " Got body from bus: #{body}"
    # Body will either be a request for data recall
    #   or stuff that needs to be filtered/recorded in the DB
    if body =~ /"Fazool,/ or body =~ / to you\./
      # We have a command.
      is_page = body =~ / to you\./ ? true : false
      actor = body.split(' ').shift
      prefix = is_page ? "page #{actor} = : >>" : ":>>"
      if body =~ /what.*time/
        channel.default_exchange.publish("say It is currently #{Time.now}, #{actor}", :routing_key => @routing_key)
      elsif body =~ /recall/
        puts "Recall request: #{body}"
        recall_logic(channel, body, is_page, actor)     
      else
        channel.default_exchange.publish("#{prefix} Sorry, #{actor} but I am not prepared to accept requests yet.", :routing_key => @routing_key)
      end
    else
      # Record this to the database.
      if body !~ /^##/ and body !~ /^You / and body !~ /^Fazool /
        actor = body.split(' ').shift
        @collection.insert_one({author: actor, quote: body, :created_at => Time.now})
      end
    end
  end
rescue Interrupt => e
  puts " Error: #{e}"
  bunny.close
  exit(1)
end





