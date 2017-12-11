#!/usr/bin/env ruby

require 'bunny'

### Now the ingestion stuff.
@client = Socket.new Socket::AF_INET, Socket::SOCK_STREAM

@client.connect Socket.pack_sockaddr_in(4999, 'del.shutdown.com')

@client.puts "connect Fazool fazpass"

### Start thread to read messages off the bus and act accordingly.
Thread.new do
  bunny = Bunny.new
  bunny.start
  channel = bunny.create_channel
  queue = channel.queue('send_to_del')
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
sendqueue = send_channel.queue('del_received')

while line = @client.gets
  send_channel.default_exchange.publish(line, :routing_key => sendqueue.name)
  puts "Incoming line: #{line}"
end

send_bunny.close
@client.close



