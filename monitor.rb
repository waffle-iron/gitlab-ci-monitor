#!/usr/bin/env ruby

require 'arduino_firmata'
require 'colorize'
require 'dotenv'
require 'json'
require 'logger'
require 'net/http'
require 'null_logger'
require 'uri'

Dotenv.load

# Logger Multiplexer.
# https://stackoverflow.com/questions/6407141/how-can-i-have-ruby-logger-log-output-to-stdout-as-well-as-file
class MultiLogger
  def initialize(*targets)
    @targets = targets
  end

  %w(log debug info warn error fatal unknown).each do |m|
    define_method(m) do |*args, &blk|
      @targets.each { |t| t.send(m, *args, &blk) }
    end
  end
end

# Fetches build info from Gitlab API.
class BuildFetcher
  BASE_URI = 'https://gitlab.com/api/v3'

  GITLAB_API_PRIVATE_TOKEN = ENV.fetch('GITLAB_API_PRIVATE_TOKEN')
  GITLAB_PROJECT_ID = ENV.fetch('GITLAB_PROJECT_ID')

  class ServerError < StandardError; end

  def initialize(logger = nil)
    @logger = logger || NullLogger.new
    @uri = URI "#{BASE_URI}/projects/#{GITLAB_PROJECT_ID}/pipelines"
  end

  def latest_build(branch = 'develop')
    @logger.info { 'Fetching pipelines ...' }

    response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new @uri
      request.add_field 'PRIVATE-TOKEN', GITLAB_API_PRIVATE_TOKEN

      http.request request
    end

    @logger.debug { @response }

    if response.code.to_i != 200
      @logger.debug { response.body.inspect.light_yellow }
      message = "#{response.message.red} (#{response.code.red}): #{response.body.underline}"
      raise ServerError, message
    end

    pipelines = JSON.parse response.body

    # returned build are already sorted
    last_build = pipelines.find { |el| el['ref'] == branch }
    @logger.debug { "Last build on #{branch}: #{last_build.inspect.light_yellow}" }

    last_build
  rescue SocketError, Net::OpenTimeout => ex
    raise ServerError, ex
  end
end

# Controls LEDs on an Arduino board with Firmata.
class LedMonitor
  LEDS = {
    red: 9,
    green: 10,
    yellow: 11
  }.freeze

  BUZZER = 5

  def initialize(logger = nil)
    @logger = logger || NullLogger.new

    @logger.debug { 'Connecting ...' }
    @arduino = ArduinoFirmata.connect

    @logger.info { "Connected with Firmata version #{@arduino.version}" }
    LEDS.keys.each { |led| turn_on led }
  end

  def close
    @logger.debug { 'Closing Firmata connection' }
    @arduino.close
  end

  def all_off
    @logger.debug { 'Turning off all leds' }
    LEDS.values.each { |pin| @arduino.digital_write pin, false }
  end

  def turn_on(led)
    @logger.debug { "Turning on #{led} led" }
    @arduino.digital_write LEDS[led], true
  end

  def buzz(duration = 0.5)
    @logger.debug { "Buzzing for #{duration} sec" }
    @arduino.digital_write BUZZER, true
    sleep duration
    @arduino.digital_write BUZZER, false
  end

  def rapid_buzz(count = 2, duration = 0.05)
    @logger.debug { "Buzzing #{count} times" }
    count.times do
      buzz duration
      sleep duration
    end
  end
end

# Use LEDs to monitor the last build status.
class BuildMonitor
  def initialize(interval, logger = nil)
    @interval = interval.to_i

    stdout_logger = Logger.new STDOUT
    file_logger = Logger.new 'monitor.log', 'daily'
    stdout_logger.level = file_logger.level = Logger::INFO unless ENV['DEBUG']
    @logger = MultiLogger.new file_logger, stdout_logger

    @status = 'success'  # assume we are in a good state
  end

  def start
    @monitor = LedMonitor.new @logger
    @build_fetcher = BuildFetcher.new @logger

    trap('SIGINT') do
      @monitor.close
      puts 'Bye!'
      exit!
    end

    loop do
      check_latest
      wait @interval
    end
  end

  def check_latest
    latest_build = @build_fetcher.latest_build

    @prev_status = @status unless pending?
    @status = latest_build['status']
    led = case @status
          when 'success' then :green
          when 'failed'  then :red
          else :yellow
          end

    @logger.info { "Build status is #{@status.colorize(led)}" }
    @monitor.all_off
    @monitor.turn_on led
    if failed?
      @monitor.buzz if was_success?
      @logger.info { "Blame: #{latest_build['sha'][0, 8].light_yellow} by #{latest_build['user']['name'].light_blue}" }
    elsif success? && was_failed?
      @monitor.rapid_buzz
      @logger.info { "Praise: #{latest_build['sha'][0, 8].light_yellow} by #{latest_build['user']['name'].light_blue}" }
    end
  rescue BuildFetcher::ServerError => ex
    @logger.error ex.message
    @monitor.all_off
    %i(yellow red).each { |ld| @monitor.turn_on ld }
  end

  def failed?
    @status == 'failed'
  end

  def success?
    @status == 'success'
  end

  def pending?
    !%w(success failed).include? @status
  end

  def was_success?
    @prev_status == 'success'
  end

  def was_failed?
    @prev_status == 'failed'
  end

  def wait(seconds)
    @logger.info { "Next check in #{seconds} secs" }
    sleep seconds
  end
end

if __FILE__ == $PROGRAM_NAME
  interval = ARGV.shift || 120
  monitor = BuildMonitor.new interval
  monitor.start
end
