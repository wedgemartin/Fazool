#!/usr/bin/env ruby

require 'bunny'

### Now the ingestion stuff.
@client = Socket.new Socket::AF_INET, Socket::SOCK_STREAM

puts "Connecting to #{ENV['FAZ_MUD_HOST']} on port #{ENV['FAZ_MUD_PORT']}"
@client.connect Socket.pack_sockaddr_in(ENV['FAZ_MUD_PORT'], ENV['FAZ_MUD_HOST'])
puts "Connected!"

unless ENV['FAZ_PASS']
  puts "ERROR: Must have a variable set for FAZ_PASS in the local env"
  exit 1
end

@client.puts "connect Fazool #{ENV['FAZ_PASS']}"

### Start thread to read messages off the bus and act accordingly.
Thread.new do
  bunny = Bunny.new
  bunny.start
  channel = bunny.create_channel
  queue = channel.queue("send_to_#{ENV['FAZ_QUEUE_NAME']}")
  begin
    queue.subscribe(:block => true) do |delivery_info, properties, body|
      puts " Got body from Processor: #{body}"
      @client.puts body
    end
  rescue Interrupt => e
    bunny.close
    exit(1)
  end
end



sendbunny = Bunny.new
sendbunny.start
send_channel = sendbunny.create_channel
sendqueue = send_channel.queue("#{ENV['FAZ_QUEUE_NAME']}_received")

while line = @client.gets
  if line =~ /^\[[a-zA-Z0-9]/ and line.split(' ').count > 1
    if line =~ /page/ or line =~ /saypose/ or line =~ /, "/
      send_channel.default_exchange.publish(line, :routing_key => sendqueue.name)
    end
  end
end

sendbunny.close
@client.close



