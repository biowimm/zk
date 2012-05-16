module ZK
  # A class that encapsulates the queue + thread that calls a callback.
  # Repsonds to `call` but places call on a queue to be delivered by a thread.
  # You will not have a useful return value from `call` so this is only useful
  # for background processing.
  class ThreadedCallback
    include ZK::Logging

    attr_reader :callback

    def initialize(callback=nil, &blk)
      @callback = callback || blk

      @state  = :running
      reopen_after_fork!
    end

    def running?
      @mutex.synchronize { @state == :running }
    end

    # how long to wait on thread shutdown before we return
    def shutdown(timeout=5)
      logger.debug { "#{self.class}##{__method__}" }

      @mutex.lock
      begin
        return if @state == :shutdown

        @state = :shutdown
        @cond.broadcast
        return unless @thread 
      ensure
        @mutex.unlock
      end

      unless @thread.join(timeout)
        logger.error { "#{self.class} timed out waiting for dispatch thread, callback: #{callback.inspect}" }
      end
    end

    def call(*args)
      @mutex.lock
      begin
        @array << args
        @cond.broadcast
      ensure
        @mutex.unlock
      end
    end

    # called after a fork to replace a dead delivery thread
    # special case, there should be ONLY ONE THREAD RUNNING, 
    # (the one that survived the fork)
    #
    # @private
    def reopen_after_fork!
      logger.debug { "#{self.class}##{__method__}" }

      unless @state == :running
        logger.debug { "#{self.class}##{__method__} state was not running: #{@state.inspect}" }
        return
      end

      if @thread and @thread.alive?
        logger.debug { "#{self.class}##{__method__} thread was still alive!" }
        return
      end

      @mutex  = Mutex.new
      @cond   = ConditionVariable.new
      @array  = []
      spawn_dispatch_thread
    end

    # shuts down the event delivery thread, but keeps the queue so we can continue
    # delivering queued events when {#resume_after_fork_in_parent} is called
    def pause_before_fork_in_parent
      return unless @thread and @thread.alive?

      @mutex.lock
      begin
        return if @state == :paused 
        @state = :paused
        @cond.broadcast
      ensure
        @mutex.unlock
      end

      logger.debug { "joining dispatch thread" }
      @thread.join
      @thread = nil
    end

    def resume_after_fork_in_parent
      raise "@state was not :paused, @state: #{@state.inspect}" if @state != :paused
      raise "@thread was not nil! #{@thread.inspect}" if @thread 

      @mutex.lock
      begin
        @state = :running
        spawn_dispatch_thread
      ensure
        @mutex.unlock
      end
    end

    protected
      def spawn_dispatch_thread
        @thread = Thread.new(&method(:dispatch_thread_body))
      end

      def dispatch_thread_body
        Thread.current.abort_on_exception = true
        while true
          args = nil

          @mutex.lock
          begin
            @cond.wait(@mutex) while @array.empty? and @state == :running

            if @state != :running
              logger.warn { "ThreadedCallback, state is #{@state.inspect}, returning" } 
              return 
            end

            args = @array.shift
          ensure
            @mutex.unlock
          end
            
          begin
            callback.call(*args)
          rescue Exception => e
            logger.error { "error caught in handler for path: #{path.inspect}, interests: #{interests.inspect}" }
            logger.error { e.to_std_format }
          end
        end
      ensure
        logger.debug { "#{self.class}##{__method__} returning" }
      end
  end
end

