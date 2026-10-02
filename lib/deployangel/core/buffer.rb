# frozen_string_literal: true

module DeployAngel
  # Bounded FIFO of payloads waiting to be sent. When full, the oldest
  # payload is dropped: losing telemetry is always preferable to growing
  # memory in the customer's process.
  class Buffer
    attr_reader :dropped

    def initialize(limit)
      @limit = limit
      @items = []
      @dropped = 0
      @mutex = Mutex.new
    end

    def push(item)
      @mutex.synchronize do
        @items << item
        while @items.size > @limit
          @items.shift
          @dropped += 1
        end
      end
    end

    def shift
      @mutex.synchronize { @items.shift }
    end

    def unshift(item)
      @mutex.synchronize { @items.unshift(item) if @items.size < @limit }
    end

    def size
      @mutex.synchronize { @items.size }
    end

    def clear
      @mutex.synchronize { @items.clear }
    end
  end
end
