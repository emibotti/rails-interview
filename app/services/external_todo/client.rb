require "faraday"
require "faraday/retry"

module ExternalTodo
  # Thin client for the External Todo API. One method per endpoint, returning
  # domain structs (see Mapper). GET/PATCH/DELETE are retried inside the request
  # (they are idempotent: PATCH sends absolute values); POST is never retried
  # because it is not idempotent and a timeout is ambiguous (the record may exist).
  class Client
    class Error < StandardError
      attr_reader :status, :body, :http_method, :path

      def initialize(message = nil, status: nil, body: nil, http_method: nil, path: nil)
        @status = status
        @body = body
        @http_method = http_method
        @path = path
        super(message || default_message)
      end

      private

      def default_message
        "#{http_method.to_s.upcase} #{path} failed with #{status || 'no response'}: #{printable(body).truncate(500)}"
      end

      # Parsed JSON bodies print as JSON, not as a Ruby inspect string.
      def printable(body)
        body.is_a?(String) ? body : JSON.generate(body)
      rescue JSON::GeneratorError
        body.to_s
      end
    end

    # Connection errors, 408, 429 and 5xx.
    class RetryableError < Error; end
    # 401 and 403: a systemic problem (wrong credentials, no permission), not a problem of one record. It counts
    # towards the circuit breaker and backs off instead of dead-lettering every record.
    class AuthenticationError < RetryableError; end
    # Ambiguous: the server may have processed the request. Matters for POST.
    class TimeoutError < RetryableError; end
    # Other 4xx. Retrying will not help.
    class ClientError < Error; end
    # 404. The caller decides the policy (404 on DELETE is success).
    class NotFoundError < ClientError; end
    # Invalid JSON or an unexpected shape.
    class InvalidResponseError < Error; end

    # What the sync logs about the last call: which request, how it ended and how many attempts it took.
    Request = Struct.new(:http_method, :path, :status, :duration_ms, :attempts, keyword_init: true)

    RETRY_STATUSES = [429, 500, 502, 503, 504].freeze
    ITEM_ATTRS = %i[name completed].freeze

    attr_reader :last_request, :attempts_total

    def self.build
      config = Rails.configuration.x.external_todo
      new(
        base_url: config.base_url,
        open_timeout: config.open_timeout,
        timeout: config.timeout,
        retry_options: config.retry_options
      )
    end

    def initialize(base_url:, open_timeout: 2, timeout: 10, retry_options: {}, logger: Rails.logger)
      @logger = logger
      @attempts_total = 0
      @connection = build_connection(base_url, open_timeout, timeout, retry_options)
    end

    def list_todo_lists
      body = request(:get, "/todolists")
      raise invalid_response!(:get, "/todolists", body, "expected a JSON array") unless body.is_a?(Array)

      body.map { |hash| Mapper.remote_list(hash) }
    end

    def create_todo_list(name:, source_id:, items: [])
      body = request(:post, "/todolists", Mapper.create_list_body(name: name, source_id: source_id, items: items))
      Mapper.remote_list(expect_hash!(:post, "/todolists", body))
    end

    def update_todo_list(external_id, name:)
      path = list_path(external_id)
      Mapper.remote_list(expect_hash!(:patch, path, request(:patch, path, Mapper.update_list_body(name: name))))
    end

    def delete_todo_list(external_id)
      request(:delete, list_path(external_id))
      true
    end

    def update_todo_item(list_external_id, item_external_id, **attrs)
      unknown = attrs.keys - ITEM_ATTRS
      raise ArgumentError, "unknown item attributes: #{unknown.join(', ')}" if unknown.any?

      path = item_path(list_external_id, item_external_id)
      body = request(:patch, path, Mapper.update_item_body(**attrs))
      Mapper.remote_item(expect_hash!(:patch, path, body))
    end

    def delete_todo_item(list_external_id, item_external_id)
      request(:delete, item_path(list_external_id, item_external_id))
      true
    end

    # Proposed endpoint (not in the current spec), used by the api_endpoint strategy.
    def create_todo_item(list_external_id, name:, completed:, source_id:)
      path = "#{list_path(list_external_id)}/todoitems"
      body = request(:post, path, Mapper.create_item_body(name: name, completed: completed, source_id: source_id))
      Mapper.remote_item(expect_hash!(:post, path, body))
    end

    private

    def build_connection(base_url, open_timeout, timeout, retry_options)
      retry_options = retry_options.symbolize_keys.reverse_merge(
        methods: %i[get patch delete],
        retry_statuses: RETRY_STATUSES,
        exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [Faraday::ConnectionFailed],
        retry_block: method(:log_retry)
      )

      Faraday.new(url: base_url, request: { open_timeout: open_timeout, timeout: timeout }) do |f|
        f.request :json
        # The parser sits outside the retry middleware: retries look at the raw status, so an error page that is
        # not JSON (an HTML 502 from a proxy) is still retried, and only the final response is parsed.
        f.response :json, content_type: /\bjson$/, parser_options: { symbolize_names: false }
        f.request :retry, retry_options
        f.adapter :net_http
      end
    end

    def request(http_method, path, body = nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @current_attempts = 1
      status = nil
      response = @connection.run_request(http_method, path.delete_prefix("/"), body, nil)
      status = response.status
      log_response(http_method, path, response.status, started)
      handle_response(http_method, path, response)
    rescue Faraday::TimeoutError => e
      log_failure(http_method, path, e)
      raise TimeoutError.new("#{http_method.to_s.upcase} #{path} timed out: #{e.message}", http_method: http_method, path: path)
    rescue Faraday::ConnectionFailed, Faraday::SSLError => e
      log_failure(http_method, path, e)
      raise RetryableError.new("#{http_method.to_s.upcase} #{path} connection failed: #{e.message}", http_method: http_method, path: path)
    rescue Faraday::ParsingError => e
      status = e.response_status
      log_failure(http_method, path, e)
      # An error status whose body is not JSON (an HTML 502 page, say) must still be reported by its status.
      raise error_for(http_method, path, status, e.response.body) if status && !status.between?(200, 299)

      raise InvalidResponseError.new("#{http_method.to_s.upcase} #{path} returned invalid JSON: #{e.message}", http_method: http_method, path: path)
    ensure
      finish_request(http_method, path, status, started)
    end

    def finish_request(http_method, path, status, started)
      @attempts_total += @current_attempts
      @last_request = Request.new(
        http_method: http_method.to_s.upcase, path: path, status: status, attempts: @current_attempts,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      )
    end

    def handle_response(http_method, path, response)
      status = response.status
      return response.body if status.between?(200, 299)

      raise error_for(http_method, path, status, response.body)
    end

    def error_for(http_method, path, status, body)
      error_class =
        if status == 404 then NotFoundError
        elsif [401, 403].include?(status) then AuthenticationError
        elsif status == 408 || RETRY_STATUSES.include?(status) || status >= 500 then RetryableError
        elsif status >= 400 then ClientError
        else InvalidResponseError
        end
      error_class.new(status: status, body: body, http_method: http_method, path: path)
    end

    def expect_hash!(http_method, path, body)
      raise invalid_response!(http_method, path, body, "expected a JSON object") unless body.is_a?(Hash)

      body
    end

    def invalid_response!(http_method, path, body, reason)
      InvalidResponseError.new(
        "#{http_method.to_s.upcase} #{path} returned an unexpected body (#{reason}): #{body.to_s.truncate(200)}",
        body: body, http_method: http_method, path: path
      )
    end

    def list_path(external_id)
      "/todolists/#{ERB::Util.url_encode(external_id)}"
    end

    def item_path(list_external_id, item_external_id)
      "#{list_path(list_external_id)}/todoitems/#{ERB::Util.url_encode(item_external_id)}"
    end

    def log_response(http_method, path, status, started)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      @logger.info("[ExternalTodo] #{http_method.to_s.upcase} #{path} -> #{status} (#{ms}ms)")
    end

    def log_failure(http_method, path, error)
      @logger.warn("[ExternalTodo] #{http_method.to_s.upcase} #{path} failed: #{error.class}: #{error.message}")
    end

    def log_retry(env:, options:, retry_count:, exception:, will_retry_in:)
      @current_attempts += 1
      reason = exception ? exception.class.name : "status #{env.status}"
      @logger.warn(
        "[ExternalTodo] retrying #{env.method.to_s.upcase} #{env.url.path} (#{reason}), " \
        "attempt #{retry_count + 1}, in #{will_retry_in.round(2)}s"
      )
    end
  end
end
