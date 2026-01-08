#!/usr/bin/env ruby

require 'stomp'

stomp_hash = {
  hosts: [
    {
      login: 'guest',
      passcode: 'guest',
      host: 'localhost',
      port: 61613
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
  nto_cmd_read: true,
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
    puts "Connected!"
  
    unless ENV['FAZ_PASS']
      puts "ERROR: Must have a variable set for FAZ_PASS in the local env"
      exit 1
    end
  end
  faz_username = ENV['FAZ_USERNAME'] || 'Fazool'
  @client.puts "connect #{faz_username} #{ENV['FAZ_PASS']}"
end

### Start thread to read messages off the bus and act accordingly.
Thread.new do
  begin
    stomp = Stomp::Client.new(stomp_hash)
    puts "Connected to STOMP broker for outbound messages"
    stomp.subscribe("/queue/send_to_#{ENV['FAZ_QUEUE_NAME']}") do |body|
      puts "Sending to MUD: #{body}"
      @client.puts body
    end
  rescue Interrupt => e
    stomp.close
    exit(1)
  end
end


main_stomp = Stomp::Client.new(stomp_hash)
puts "Connected to STOMP broker for inbound messages"

while 1 == 1
  do_connect
  if ENV['FAZ_KEEPALIVE']
    Thread.new do 
      while 1 == 1
        sleep ENV['FAZ_KEEPALIVE']
        begin
          @client.puts '@@'
        rescue => e
          puts "Reconnecting!!"
          do_connect
        end
      end
    end
  end
  begin
    @client.puts "say HELLO"
    while line = @client.gets
      puts " GOT LINE: #{line}"
      if line =~ /^\[[a-zA-Z0-9]/ and line.split(' ').count > 1
        if line =~ /page/ or line =~ /saypose/ or line =~ /, "/
          puts "Publishing to queue: #{ENV['FAZ_QUEUE_NAME']}_received - #{line.strip}"
          main_stomp.publish("/queue/#{ENV['FAZ_QUEUE_NAME']}_received", line)
        end
      else
        puts " Dunno what to do with line: #{line}"
      end
    end
  rescue => e
    puts " Got error: #{e} sleeping for 10..."
    sleep(90)
  end
end

main_stomp.close
