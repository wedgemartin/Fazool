#!/usr/bin/env ruby
# frozen_string_literal: true

require 'stomp'

stomp_hash = {
  hosts: [
    {
      login: 'guest',
      passcode: 'guest',
      host: 'localhost',
      port: 61_613
    }
  ],
  reliable: true,
  initial_reconnect_delay: 0.01,
  max_reconnect_delay: 30.0,
  use_exponential_back_off: true,
  back_off_multiplier: 2,
  max_reconnect_attempts: 0,
  randomize: false,
  connect_timeout: 0,
  connect_headers: {},
  parse_timeout: 5,
  logger: nil,
  dmh: false,
  closed_check: true,
  hbser: false,
  stompconn: false,
  usecrlf: false,
  max_hbread_fails: 0,
  max_hbrlck_fails: 0,
  fast_hbs_adjust: 0.0,
  connread_timeout: 0,
  tcp_nodelay: true,
  start_timeout: 0,
  sslctx_newparm: nil,
  ssl_post_conn_check: true,
  nto_cmd_read: true
}

def do_connect
  ### Now the ingestion stuff.
  if ENV['FAZ_MUD_USE_SSL']
    require 'openssl'
    require 'socket'
    sock = TCPSocket.new(ENV['FAZ_MUD_HOST'], ENV['FAZ_MUD_PORT'])
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_NONE)
    @socket = OpenSSL::SSL::SSLSocket.new(sock, ctx).tap do |socket|
      socket.sync_close = true
      socket.connect
    end
    @client = @socket
  else
    @client = Socket.new Socket::AF_INET, Socket::SOCK_STREAM

    puts "Connecting to #{ENV['FAZ_MUD_HOST']} on port #{ENV['FAZ_MUD_PORT']}"
    @client.connect Socket.pack_sockaddr_in(ENV['FAZ_MUD_PORT'], ENV['FAZ_MUD_HOST'])
    puts 'Connected!'

    unless ENV['FAZ_PASS']
      puts 'ERROR: Must have a variable set for FAZ_PASS in the local env'
      exit 1
    end
  end
  faz_username = ENV['FAZ_USERNAME'] || 'Fazool'
  @client.puts "connect #{faz_username} #{ENV['FAZ_PASS']}"
end

### Start thread to read messages off the bus and act accordingly.
Thread.new do
  stomp = Stomp::Client.new(stomp_hash)
  puts 'Connected to STOMP broker for outbound messages'
  stomp.subscribe("/queue/send_to_#{ENV['FAZ_QUEUE_NAME']}") do |msg|
    puts "DEBUG: Received message object: #{msg.class}"
    body = msg.body
    puts "DEBUG: Extracted body: #{body.inspect}"
    puts "Sending to MUD: #{body}"
    @client.puts body
  end
rescue Interrupt
  stomp.close
  exit(1)
end

main_stomp = Stomp::Client.new(stomp_hash)
puts 'Connected to STOMP broker for inbound messages'

while 1 == 1
  do_connect
  @keepalive_failed = false
  keepalive_thread = nil

  if ENV['FAZ_KEEPALIVE']
    keepalive_thread = Thread.new do
      until @keepalive_failed
        sleep ENV['FAZ_KEEPALIVE'].to_i
        begin
          @client.puts '@@'
        rescue StandardError => e
          puts "Keepalive failed: #{e}"
          @keepalive_failed = true
          begin
            @client.close
          rescue StandardError
            nil
          end
          break
        end
      end
    end
  end

  begin
    @client.puts 'say HELLO'
    while !@keepalive_failed && (line = @client.gets)
      puts " GOT LINE: #{line}"
      if line =~ /^\[[a-zA-Z0-9]/ && (line.split(' ').count > 1)
        if line =~ /page/ || line =~ /saypose/ || line =~ /, "/
          puts "Publishing to queue: #{ENV['FAZ_QUEUE_NAME']}_received - #{line.strip}"
          main_stomp.publish("/queue/#{ENV['FAZ_QUEUE_NAME']}_received", line)
        end
      else
        puts " Dunno what to do with line: #{line}"
      end
    end
  rescue StandardError => e
    puts " Got error: #{e}"
  ensure
    @keepalive_failed = true
    keepalive_thread&.kill
    begin
      @client.close
    rescue StandardError
      nil
    end
    puts 'Connection closed, reconnecting in 10 seconds...'
    sleep(10)
  end
end

main_stomp.close
