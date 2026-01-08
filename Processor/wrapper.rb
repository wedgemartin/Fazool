#!/usr/bin/env ruby

require 'daemons'

Daemons.run_proc('processor.rb')
