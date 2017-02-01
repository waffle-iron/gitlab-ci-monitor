#!/usr/bin/env ruby

require 'active_support/core_ext/object/inclusion'
require 'active_support/core_ext/numeric/time'
require 'arduino_firmata'
require 'colorize'
require 'dotenv'
require 'httparty'
require 'logger'
require 'null_logger'

Dotenv.load

# Fetches build info from Gitlab API.
class BuildFetcher
  include HTTParty
  base_uri 'https://gitlab.com/api/v3'

  GITLAB_API_PRIVATE_TOKEN = ENV['GITLAB_API_PRIVATE_TOKEN']
  GITLAB_PROJECT_ID = ENV['GITLAB_PROJECT_ID']

  class ServerError < StandardError; end

  def initialize(logger = nil)
    @logger = logger || NullLogger.new
    @options = {
      headers: {
        'PRIVATE-TOKEN' => GITLAB_API_PRIVATE_TOKEN
      }
    }
    @project_id = GITLAB_PROJECT_ID
  end

  def latest_build(branch = 'develop')
    @logger.info { 'Fetching pipelines ...' }
    pipelines = self.class.get "/projects/#{@project_id}/pipelines", @options

    if pipelines.code != 200
      @logger.debug pipelines.inspect.light_yellow
      message = "#{pipelines.message.red} (#{pipelines.code.to_s.red}): #{pipelines.body.underline}"
      raise ServerError, message
    end

    # returned build are already sorted
    last_build = pipelines.find { |el| el['ref'] == branch }
    @logger.debug { "Last build on #{branch}: #{last_build.inspect.light_yellow}" }

    last_build
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
    @logger = Logger.new STDOUT
    @logger.level = Logger::INFO unless ENV['DEBUG']

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
    !@status.in? %w(success failed)
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
  interval = ARGV.shift || 2.minutes
  monitor = BuildMonitor.new interval
  monitor.start
end
