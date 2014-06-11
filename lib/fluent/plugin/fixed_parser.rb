#
# This module is copied from fluentd/lib/fluent/parser.rb and
# fixed not to overwrite 'time' (reserve nil) when time not found in parsed string.
module FluentExt; end

class FluentExt::TextParser
  class GenericParser
    include Fluent::Configurable

    config_param :time_key, :string, :default => 'time'
    config_param :time_format, :string, :default => nil
    config_param :time_parse, :bool, :default => true

    attr_accessor :log

    def initialize
      super

      @cache1_key = nil
      @cache1_time = nil
      @cache2_key = nil
      @cache2_time = nil

      @log = nil
    end

    def parse_time(record)
      time = nil

      unless @time_parse
        return time, record
      end

      if value = record.delete(@time_key)
        if @cache1_key == value
          time = @cache1_time
        elsif @cache2_key == value
          time = @cache2_time
        else
          begin
            time = if @time_format
                     Time.strptime(value, @time_format).to_i
                   else
                     Time.parse(value).to_i
                   end
            @cache1_key = @cache2_key
            @cache1_time = @cache2_time
            @cache2_key = value
            @cache2_time = time
          rescue TypeError, ArgumentError => e
            @log.warn "Failed to parse time", :key => @time_key, :value => value
            record[@time_key] = value
          end
        end
      end

      return time, record
    end
  end

  class RegexpParser < GenericParser
    include Fluent::Configurable

    config_param :suppress_parse_error_log, :bool, :default => false
    config_param :emit_parse_failures, :bool, :default => false

    def initialize(regexp, conf={})
      super()
      @regexp = regexp
      unless conf.empty?
        configure(conf)
      end
    end

    def call(text)
      parse_failure = false
      m = @regexp.match(text)
      unless m
        unless @suppress_parse_error_log
          @log.warn "pattern not match: #{text}"
        end

        parse_failure = true
        unless @emit_parse_failures
          return nil, nil
        end
      end

      record = {}
      if not parse_failure
        m.names.each {|name|
          record[name] = m[name] if m[name]
        }
      else
        record['time'] = Time.at(Fluent::Engine.now).to_s
        record['message'] = text
      end

      parse_time(record)
    end
  end

  class JSONParser < GenericParser
    def call(text)
      record = Yajl.load(text)
      return parse_time(record)
    rescue Yajl::ParseError
      unless @suppress_parse_error_log
        @log.warn "pattern not match(json): #{text.inspect}: #{$!}"
      end

      return nil, nil
    end
  end

  class LabeledTSVParser < GenericParser
    def call(text)
      record = Hash[text.split("\t").map{|p| p.split(":", 2)}]
      parse_time(record)
    end
  end

  class ValuesParser < GenericParser
    config_param :keys, :string

    def configure(conf)
      super
      @keys = @keys.split(",")
    end

    def values_map(values)
      Hash[@keys.zip(values)]
    end
  end

  class TSVParser < ValuesParser
    config_param :delimiter, :string, :default => "\t"

    def call(text)
      return parse_time(values_map(text.split(@delimiter)))
    end
  end

  class CSVParser < ValuesParser
    def initialize
      super
      require 'csv'
    end

    def call(text)
      return parse_time(values_map(CSV.parse_line(text)))
    end
  end

  class ApacheParser < GenericParser
    include Fluent::Configurable

    REGEXP = /^(?<host>[^ ]*) [^ ]* (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^ ]*) +\S*)?" (?<code>[^ ]*) (?<size>[^ ]*)(?: "(?<referer>[^\"]*)" "(?<agent>[^\"]*)")?$/

    def initialize
      super

      @time_key = "time"
      @time_format = "%d/%b/%Y:%H:%M:%S %z"
   end

    def call(text)
      m = REGEXP.match(text)
      unless m
        unless @suppress_parse_error_log
          @log.warn "pattern not match: #{text.inspect}"
        end

        return nil, nil
      end

      host = m['host']
      host = (host == '-') ? nil : host

      user = m['user']
      user = (user == '-') ? nil : user

      time = m['time']

      method = m['method']
      path = m['path']

      code = m['code'].to_i
      code = nil if code == 0

      size = m['size']
      size = (size == '-') ? nil : size.to_i

      referer = m['referer']
      referer = (referer == '-') ? nil : referer

      agent = m['agent']
      agent = (agent == '-') ? nil : agent

      record = {
        "time" => time,
        "host" => host,
        "user" => user,
        "method" => method,
        "path" => path,
        "code" => code,
        "size" => size,
        "referer" => referer,
        "agent" => agent,
      }

      parse_time(record)
    end
  end

  TEMPLATE_FACTORIES = {
    'apache' => Proc.new { RegexpParser.new(/^(?<host>[^ ]*) [^ ]* (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^ ]*) +\S*)?" (?<code>[^ ]*) (?<size>[^ ]*)(?: "(?<referer>[^\"]*)" "(?<agent>[^\"]*)")?$/, {'time_format'=>"%d/%b/%Y:%H:%M:%S %z"}) },
    'apache2' => Proc.new { ApacheParser.new },
    'nginx' => Proc.new { RegexpParser.new(/^(?<remote>[^ ]*) (?<host>[^ ]*) (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^ ]*) +\S*)?" (?<code>[^ ]*) (?<size>[^ ]*)(?: "(?<referer>[^\"]*)" "(?<agent>[^\"]*)")?$/,  {'time_format'=>"%d/%b/%Y:%H:%M:%S %z"}) },
    'syslog' => Proc.new { RegexpParser.new(/^(?<time>[^ ]*\s*[^ ]* [^ ]*) (?<host>[^ ]*) (?<ident>[a-zA-Z0-9_\/\.\-]*)(?:\[(?<pid>[0-9]+)\])?[^\:]*\: *(?<message>.*)$/, {'time_format'=>"%b %d %H:%M:%S"}) },
    'json' => Proc.new { JSONParser.new },
    'csv' => Proc.new { CSVParser.new },
    'tsv' => Proc.new { TSVParser.new },
    'ltsv' => Proc.new { LabeledTSVParser.new },
  }

  def self.register_template(name, regexp_or_proc, time_format=nil)

    factory = if regexp_or_proc.is_a?(Regexp)
                regexp = regexp_or_proc
                Proc.new { RegexpParser.new(regexp, {'time_format'=>time_format}) }
              else
                Proc.new { proc }
              end
    TEMPLATE_FACTORIES[name] = factory
  end

  attr_accessor :log
  attr_reader :parser

  def initialize(logger)
    @log = logger
    @parser = nil
  end

  def configure(conf, required=true)
    format = conf['format']

    if format == nil
      if required
        raise Fluent::ConfigError, "'format' parameter is required"
      else
        return nil
      end
    end

    if format[0] == ?/ && format[format.length-1] == ?/
      # regexp
      begin
        regexp = Regexp.new(format[1..-2])
        if regexp.named_captures.empty?
          raise "No named captures"
        end
      rescue
        raise Fluent::ConfigError, "Invalid regexp '#{format[1..-2]}': #{$!}"
      end
      @parser = RegexpParser.new(regexp)

    else
      # built-in template
      factory = TEMPLATE_FACTORIES[format]
      unless factory
        raise Fluent::ConfigError, "Unknown format template '#{format}'"
      end
      @parser = factory.call

    end

    @parser.log = @log

    if @parser.respond_to?(:configure)
      @parser.configure(conf)
    end

    return true
  end

  def parse(text)
    return @parser.call(text)
  end
end
