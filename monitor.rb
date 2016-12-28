#!/usr/bin/env ruby

require 'arduino_firmata'
require 'dotenv'
require 'httparty'
require 'logger'

Dotenv.load

GITLAB_API_ENDPOINT = 'https://gitlab.com/api/v3'
GITLAB_API_PRIVATE_TOKEN = ENV['GITLAB_API_PRIVATE_TOKEN']
GITLAB_PROJECT_ID = ENV['GITLAB_PROJECT_ID']

LEDS = {
  red: 9,
  green: 10,
  yellog: 11
}

$logger = Logger.new STDOUT
$logger.level = Logger::INFO unless ENV['DEBUG']

def latest_build(branch = 'develop')
  $logger.info { 'Fetching pipelines ...' }
  pipelines = HTTParty.get "#{GITLAB_API_ENDPOINT}/projects/#{GITLAB_PROJECT_ID}/pipelines",
                           headers: { 'PRIVATE-TOKEN' => GITLAB_API_PRIVATE_TOKEN }

  last_build = pipelines.find { |el| el['ref'] == branch }
  $logger.debug { "Last build on #{branch}: #{last_build}" }

  last_build
end

def check_build(last_build)
  LEDS.values.each { |pin| $arduino.digital_write pin, false }

  status = last_build['status']
  led = case status
        when 'running' then :yellow
        when 'success' then :green
        else :red
        end

  $logger.info { "Last build status is #{status}, turning #{led} led" }
  $arduino.digital_write LEDS[led], true
end

def wait(seconds)
  $logger.info { "Next check in #{seconds} secs" }
  sleep seconds
end

$arduino = ArduinoFirmata.connect
$logger.info { "Connected with Firmata version #{$arduino.version}" }

trap('SIGINT') do
  $arduino.close
  exit!
end

loop do
  check_build latest_build
  wait 60
end
