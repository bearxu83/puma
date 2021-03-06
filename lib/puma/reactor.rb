module Puma
  class Reactor
    DefaultSleepFor = 5

    def initialize(server, app_pool)
      @server = server
      @events = server.events
      @app_pool = app_pool

      @mutex = Mutex.new
      @ready, @trigger = IO.pipe
      @input = []
      @sleep_for = DefaultSleepFor
      @timeouts = []
    end

    def run
      sockets = [@ready]

      while true
        ready = IO.select sockets, nil, nil, @sleep_for

        if ready and reads = ready[0]
          reads.each do |c|
            if c == @ready
              @mutex.synchronize do
                @ready.read(1) # drain
                sockets += @input
                @input.clear
              end
            else
              # We have to be sure to remove it from the timeout
              # list or we'll accidentally close the socket when
              # it's in use!
              if c.timeout_at
                @timeouts.delete c
              end

              begin
                if c.try_to_finish
                  @app_pool << c
                  sockets.delete c
                end
              # The client doesn't know HTTP well
              rescue HttpParserError => e
                c.close
                sockets.delete c

                @events.parse_error @server, c.env, e

              rescue EOFError
                c.close
                sockets.delete c
              end
            end
          end
        end

        unless @timeouts.empty?
          now = Time.now

          while @timeouts.first.timeout_at < now
            c = @timeouts.shift
            sockets.delete c
            c.close

            break if @timeouts.empty?
          end

          calculate_sleep
        end
      end
    end

    def run_in_thread
      @thread = Thread.new { run }
    end

    def calculate_sleep
      if @timeouts.empty?
        @sleep_for = DefaultSleepFor
      else
        diff = @timeouts.first.timeout_at.to_f - Time.now.to_f

        if diff < 0.0
          @sleep_for = 0
        else
          @sleep_for = diff
        end
      end
    end

    def add(c)
      @mutex.synchronize do
        @input << c
        @trigger << "!"

        if c.timeout_at
          @timeouts << c
          @timeouts.sort! { |a,b| a.timeout_at <=> b.timeout_at }

          calculate_sleep
        end
      end
    end
  end
end
