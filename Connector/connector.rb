#!/usr/bin/env ruby

require 'stomp'

stomp_hash = {
  hosts: [
    {
      login: 'guest',
      passcode: 'guest',
      # vhost: 'o',
      host:  'localhost',
      port:  61613
    }
  ],
  reliable: true,                  # reliable (use failover)
  initial_reconnect_delay: 0.01,   # initial delay before reconnect (secs)
  max_reconnect_delay: 30.0,       # max delay before reconnect
  use_exponential_back_off: true,  # increase delay between reconnect attpempts
  back_off_multiplier: 2,          # next delay multiplier
  max_reconnect_attempts: 0,       # retry forever, use # for maximum attempts
  randomize: false,                # do not radomize hosts hash before reconnect
  connect_timeout: 0,              # Timeout for TCP/TLS connects, use # for max seconds
  connect_headers: {},             # user supplied CONNECT headers (req'd for Stomp 1.1+)
  parse_timeout: 5,                # IO::select wait time on socket reads
  logger: nil,                     # user suplied callback logger instance
  dmh: false,                      # do not support multihomed IPV4 / IPV6 hosts during failover
  closed_check: true,              # check first if closed in each protocol method
  hbser: false,                    # raise on heartbeat send exception
  stompconn: false,                # Use STOMP instead of CONNECT
  usecrlf: false,                  # Use CRLF command and header line ends (1.2+)
  max_hbread_fails: 0,             # Max HB read fails before retry.  0 => never retry
  max_hbrlck_fails: 0,             # Max HB read lock obtain fails before retry.  0 => never retry
  fast_hbs_adjust: 0.0,            # Fast heartbeat senders sleep adjustment, seconds, needed ...
  # For fast heartbeat senders.  'fast' == YMMV.  If not
  # correct for your environment, expect unnecessary fail overs
  connread_timeout: 0,             # Timeout during CONNECT for read of CONNECTED/ERROR, secs
  tcp_nodelay: true,               # Turns on the TCP_NODELAY socket option; disables Nagle's algorithm
  start_timeout: 0,                # Timeout around Stomp::Client initialization
  sslctx_newparm: nil,             # Param for SSLContext.new
  ssl_post_conn_check: true,       # Further verify broker identity
  nto_cmd_read: true,              # No timeout on COMMAND read
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
  # bunny = Bunny.new
  # bunny.start
  # channel = bunny.create_channel
  # queue = channel.queue("send_to_#{ENV['FAZ_QUEUE_NAME']}")

  begin
    stomp = Stomp::Client.new(stomp_hash)
    stomp.subscribe("/queue/send_to#{ENV['FAZ_QUEUE_NAME']}") do |body|
      puts " Got body from Processor: #{body}"
      @client.puts body
    end
  rescue Interrupt => e
    stomp.close
    exit(1)
  end
end


main_stomp = Stomp::Client.new(stomp_hash)
# main_stomp.subscribe("/queue/#{ENV['FAZ_QUEUE_NAME']}_received")

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
          puts "Sending '#{line}' to #{ENV['FAZ_QUEUE_NAME']}_received}"
          main_stomp.publish("/queue/#{ENV['FAZ_QUEUE_NAME']}_received}", line)
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
