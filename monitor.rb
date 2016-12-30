#!/usr/bin/env ruby

require 'arduino_firmata'
require 'dotenv'
require 'httparty'
require 'logger'

Dotenv.load

# Fetches build info from Gitlab API.
class BuildFetcher
  include HTTParty
  base_uri 'https://gitlab.com/api/v3'

  GITLAB_API_PRIVATE_TOKEN = ENV['GITLAB_API_PRIVATE_TOKEN']
  GITLAB_PROJECT_ID = ENV['GITLAB_PROJECT_ID']

  def initialize(logger)
    @logger = logger
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

    # returned build are already sorted
    last_build = pipelines.find { |el| el['ref'] == branch }
    @logger.debug { "Last build on #{branch}: #{last_build}" }

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

  def initialize(logger)
    @logger = logger

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
    @logger.debug { "Turning on #{led} leds" }
    @arduino.digital_write LEDS[led], true
  end
end

# Use LEDs to monitor the last build status.
class BuildMonitor
  def initialize
    @logger = Logger.new STDOUT
    @logger.level = Logger::INFO unless ENV['DEBUG']
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
      wait 60
    end
  end

  def check_latest
    latest_build = @build_fetcher.latest_build

    status = latest_build['status']
    led = case status
          when 'success' then :green
          when 'failed'  then :red
          else :yellow
          end

    @logger.info { "Last build status is #{status}, turning #{led} led" }
    @monitor.all_off
    @monitor.turn_on led
  end

  def wait(seconds)
    @logger.info { "Next check in #{seconds} secs" }
    sleep seconds
  end
end

if __FILE__ == $PROGRAM_NAME
  monitor = BuildMonitor.new
  monitor.start
end
