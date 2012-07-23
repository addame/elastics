module Flex
  # Generic Flex::Template object.
  # This class represents a generic Flex::Template object. It is used as the base class by all the more specific Flex::Template::* classes.
  # You  usually don't need to instantiate this class manually, since it is usually used internally.
  # For more details about templates, see the documentation.
  class Template

    include Base

    def self.variables
      Variables.new
    end

    attr_reader :method, :path, :data, :variables, :tags, :partials

    def initialize(method, path, data=nil, vars=nil)
      @method = method.to_s.upcase
      raise ArgumentError, "#@method method not supported" \
            unless %w[HEAD GET PUT POST DELETE].include?(@method)
      @path          = path =~ /^\// ? path : "/#{path}"
      @data          = Utils.data_from_source(data)
      @instance_vars = vars
    end

    def setup(host_flex, name=nil, source_vars=nil)
      @host_flex   = host_flex
      @name        = name
      @source_vars = source_vars
      self
    end

    def render(vars={})
      do_render(vars) do |response, int|
        Result.new(self, int[:vars], response)
      end
    end

    def to_a(vars={})
      int = interpolate(vars)
      a = [method, int[:path], int[:data], @instance_vars]
      2.times { a.pop if a.last.nil? }
      a
    end

    def to_curl(vars={})
      to_curl_string interpolate(vars, strict=true)
    end

    def to_flex(name=nil)
      (name ? {name.to_s => to_a} : to_a).to_yaml
    end

  private

    def do_render(vars={})
      int          = interpolate(vars, strict=true)
      path         = build_path(int, vars)
      encoded_data = build_data(int, vars)
      response     = Configuration.http_client.request(method, path, encoded_data)

      # used in Flex.exist?
      return response.status == 200 if method == 'HEAD'

      if Configuration.raise_proc.call(response)
        int[:vars][:raise].is_a?(FalseClass) ? return : raise(HttpError.new(response, caller_line))
      end

      result = yield(response, int)

    rescue NameError => e
      if e.name == :request
        raise MissingHttpClientError, 'you should install the gem "patron" (recommended for performances) or "rest-client", ' +
                                      'or provide your own http-client interface and set Flex::Configuration.http_client'
      else
        raise
      end
    ensure
      to_logger(path, encoded_data, result) if int && Configuration.debug && Configuration.logger.level == 0
    end

    def build_path(int, vars)
      params = int[:vars][:params]
      path   = vars[:path] || int[:path]
      if params
        path << ((path =~ /\?/) ? '&' : '?')
        path << params.map { |p| p.join('=') }.join('&')
      end
      path
    end

    def build_data(int, vars)
      data = vars[:data] && Utils.data_from_source(vars[:data]) || int[:data]
      (data.nil? || data.is_a?(String)) ? data : MultiJson.encode(data)
    end

    def to_logger(path, encoded_data, result)
      h = {}
      h[:method] = method
      h[:path]   = path
      h[:data]   = MultiJson.decode(encoded_data) unless encoded_data.nil?
      h[:result] = result if result && Configuration.debug_result
      log        = Configuration.debug_to_curl ? to_curl_string(h) : Utils.stringified_hash(h).to_yaml
      Configuration.logger.debug "[FLEX] Rendered #{caller_line}\n#{log}"
    end

    def caller_line
      method_name = @host_flex && @name && "#{@host_flex.host_class}.#@name"
      line = caller.find{|l| l !~ %r|/flex/lib/flex/[^\.]+\.rb|}
      ll = ''
      ll << "#{method_name} from " if method_name
      ll << "#{line}"
      ll
    end

    def to_curl_string(h)
      pretty = h[:path] =~ /\?/ ? '&pretty=1' : '?pretty=1'
      curl =  %(curl -X#{method} "#{Configuration.base_uri}#{h[:path]}#{pretty}")
      if h[:data]
        data = if h[:data].is_a?(String)
                 h[:data].length > 1024 ? h[:data][0,1024] + '...(truncated display)' : h[:data]
               else
                 MultiJson.encode(h[:data], :pretty => true)
               end
        curl << %( -d '\n#{data}\n')
      end
      curl
    end

    def interpolate(*args)
      tags        = Tags.new
      stringified = tags.stringify(:path => @path, :data => @data)
      @partials, @tags = tags.map(&:name).partition{|n| n.to_s =~ /^_/}
      @variables = Configuration.variables.deep_dup
      @variables.add(self.class.variables)
      @variables.add(@host_flex.variables) if @host_flex
      @variables.add(@source_vars, @instance_vars, tags.variables)
      instance_eval <<-ruby, __FILE__, __LINE__
        def interpolate(vars={}, strict=false)
          return {:path => path, :data => data, :vars => vars} if vars.empty? && !strict
          sym_vars = {}
          vars.each{|k,v| sym_vars[k.to_sym] = v} # so you can pass the rails params hash
          merged = @variables.deep_merge sym_vars
          vars   = process_vars(merged)
          obj    = #{stringified}
          obj[:vars] = vars
          obj    = prune(obj, vars[:no_pruning])
          obj
        end
      ruby
      interpolate(*args)
    end

    # prunes the branch when the leaf is nil
    # also removes empty path segments
    # and compact.flatten the Array values
    def prune(obj, no_pruning)
      case obj
      when Array
        return if obj.empty?
        a = obj.map do |i|
              next if i.nil?
              prune(i, no_pruning)
            end.compact.flatten
        a unless a.empty?
      when Hash
        return if obj.empty?
        h = {}
        obj.each do |k, v|
          next if v.nil?
          v = case
              when k == :path
                v.gsub(/\/+/, '/')
              when no_pruning.include?(k)
                v
              else
                prune(v, no_pruning)
              end
          h[k] = v unless v.nil?
        end
        h unless h.empty?
      else
        obj
      end
    end

  end
end