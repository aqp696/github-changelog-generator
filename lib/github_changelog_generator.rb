#!/usr/bin/env ruby

require 'github_api'
require 'json'
require 'colorize'
require 'benchmark'

require_relative 'github_changelog_generator/parser'
require_relative 'github_changelog_generator/generator'
require_relative 'github_changelog_generator/version'

module GitHubChangelogGenerator
  class ChangelogGenerator

    attr_accessor :options, :all_tags, :github

    PER_PAGE_NUMBER = 30

    def initialize

      @options = Parser.parse_options

      if options[:verbose]
        puts 'Input options:'
        pp options
        puts ''
      end

      github_token

      github_options = {per_page: PER_PAGE_NUMBER}
      github_options[:oauth_token] = @github_token unless @github_token.nil?
      github_options[:endpoint] = options[:github_endpoint] unless options[:github_endpoint].nil?
      github_options[:site] = options[:github_endpoint] unless options[:github_site].nil?

      @github = Github.new github_options

      @generator = Generator.new(@options)

      @all_tags = self.get_all_tags
      @pull_requests = self.get_filtered_pull_requests
      if @options[:issues]
        @issues = self.get_all_issues
        fetch_event_for_issues(@issues)
        detect_actual_closed_dates
      else
        @issues = []
      end

      @tag_times_hash = {}
    end

    def detect_actual_closed_dates

      if @options[:verbose]
        print "Fetching close commit date for issues...\r"
      end

      threads = []
      @issues.each{|issue|
        threads << Thread.new {
          find_closed_date_by_commit(issue)
        }
      }
      threads.each { |thr| thr.join }

      if @options[:verbose]
        puts 'Fetching close commit date for issues: Done!'
      end
    end

    def find_closed_date_by_commit(issue)
      unless issue['events'].nil?
        # reverse! - to find latest closed event. (event goes in date order)
        issue['events'].reverse!.each{|event|
          if event[:event].eql? 'closed'
            if event[:commit_id].nil?
              issue[:actual_date] = issue[:closed_at]
            else
              commit = @github.git_data.commits.get @options[:user], @options[:project], event[:commit_id]
              issue[:actual_date] = commit[:author][:date]
            end
            break
          end
        }
      end
      #TODO: assert issues, that remain without 'actual_date' hash for some reason.
    end

    def print_json(json)
      puts JSON.pretty_generate(json)
    end

    def exec_command(cmd)
      exec_cmd = "cd #{$project_path} and #{cmd}"
      %x[#{exec_cmd}]
    end

    def get_all_closed_pull_requests
      if @options[:verbose]
        print "Fetching pull requests...\r"
      end
      response = @github.pull_requests.list @options[:user], @options[:project], :state => 'closed'

      pull_requests = []
      page_i = 0
      response.each_page do |page|
        page_i += PER_PAGE_NUMBER
        count_pages = response.count_pages
        print "Fetching pull requests... #{page_i}/#{count_pages * PER_PAGE_NUMBER}\r"
        pull_requests.concat(page)
      end
      print "                               \r"

      if @options[:verbose]
        puts "Received pull requests: #{pull_requests.count}"
      end

      pull_requests
    end

    def get_filtered_pull_requests

      pull_requests = self.get_all_closed_pull_requests

      unless @options[:pull_request_labels].nil?

        if @options[:verbose]
          puts 'Filter all pull requests by labels.'
        end

        filtered_pull_requests = pull_requests.select { |pull_request|
          #fetch this issue to get labels array
          issue = @github.issues.get @options[:user], @options[:project], pull_request.number

          #compare is there any labels from @options[:labels] array
          issue_without_labels = !issue.labels.map { |label| label.name }.any?

          if @options[:verbose]
            puts "Filter request \##{issue.number}."
          end

          if @options[:pull_request_labels].any?
            select_by_label = (issue.labels.map { |label| label.name } & @options[:pull_request_labels]).any?
          else
            select_by_label = false
          end

          select_by_label | issue_without_labels
        }

        if @options[:verbose]
          puts "Filtered pull requests with specified labels and w/o labels: #{filtered_pull_requests.count}"
        end
        return filtered_pull_requests
      end

      pull_requests
    end

    def compund_changelog

      log = "# Changelog\n\n"

      if @options[:last]
        log += self.generate_log_between_tags(self.all_tags[0], self.all_tags[1])
      elsif @options[:tag1] and @options[:tag2]
        tag1 = @options[:tag1]
        tag2 = @options[:tag2]
        tags_strings = []
        self.all_tags.each { |x| tags_strings.push(x['name']) }

        if tags_strings.include?(tag1)
          if tags_strings.include?(tag2)
            hash = Hash[tags_strings.map.with_index.to_a]
            index1 = hash[tag1]
            index2 = hash[tag2]
            log += self.generate_log_between_tags(self.all_tags[index1], self.all_tags[index2])
          else
            puts "Can't find tag #{tag2} -> exit"
            exit
          end
        else
          puts "Can't find tag #{tag1} -> exit"
          exit
        end
      else
        log += self.generate_log_for_all_tags
      end

      log += "\n\n\\* *This changelog was generated by [github_changelog_generator](https://github.com/skywinder/Github-Changelog-Generator)*"

      output_filename = "#{@options[:output]}"
      File.open(output_filename, 'w') { |file| file.write(log) }

      puts "Done! Generated log placed in #{`pwd`.strip!}/#{output_filename}"

    end

    def generate_log_for_all_tags
      log = ''

      if @options[:verbose]
        puts "Fetching tags dates.."
      end

      # Async fetching tags:
      threads = []
      @all_tags.each { |tag|
        # explicit set @tag_times_hash to write data safety.
        threads << Thread.new { self.get_time_of_tag(tag, @tag_times_hash) }
      }
      threads.each { |thr| thr.join }

      if @options[:verbose]
        puts "Sorting tags.."
      end

      @all_tags.sort_by! { |x| self.get_time_of_tag(x) }.reverse!

      if @options[:verbose]
        puts "Generating log.."
      end

      (1 ... self.all_tags.size).each { |index|
        log += self.generate_log_between_tags(self.all_tags[index], self.all_tags[index-1])
      }

      log += generate_log_between_tags(nil, self.all_tags.last)

      log
    end

    def is_megred(number)
      @github.pull_requests.merged? @options[:user], @options[:project], number
    end

    def get_all_tags

      if @options[:verbose]
        print "Fetching tags...\r"
      end

      response = @github.repos.tags @options[:user], @options[:project]

      tags = []
      page_i = 0
      count_pages = response.count_pages
      response.each_page do |page|
        page_i += PER_PAGE_NUMBER
        print "Fetching tags... #{page_i}/#{count_pages * PER_PAGE_NUMBER}\r"
        tags.concat(page)
      end
      print "                               \r"
      if @options[:verbose]
        puts "Found #{tags.count} tags"
      end

      tags
    end

    def github_token
      if @options[:token]
        return @github_token ||= @options[:token]
      end

      env_var = ENV.fetch 'CHANGELOG_GITHUB_TOKEN', nil

      unless env_var
        puts "Warning: No token provided (-t option) and variable $CHANGELOG_GITHUB_TOKEN was not found.".yellow
        puts "This script can make only 50 requests to GitHub API per hour without token!".yellow
      end

      @github_token ||= env_var

    end


    def generate_log_between_tags(older_tag, newer_tag)

      if newer_tag.nil?
        puts "Can't find tag -> terminate"
        exit 1
      end

      newer_tag_time = self.get_time_of_tag(newer_tag)
      newer_tag_name = newer_tag['name']

      filtered_pull_requests = delete_by_time(@pull_requests, :merged_at, newer_tag_time, older_tag)
      filtered_issues = delete_by_time(@issues, :actual_date, newer_tag_time, older_tag)

      older_tag_name  = older_tag.nil? ? nil : older_tag['name']

      if @options[:filter_issues_by_milestone]
        #delete excess irrelevant issues (according milestones)
        filtered_issues.select! { |issue|
          if issue.milestone.nil?
            true
          else
            #check, that this milestone in tag list:
            milestone_is_tag = @all_tags.find { |tag|
              tag.name == issue.milestone.title
            }
            milestone_is_tag.nil?
          end

        }

        #add missed issues (according milestones)
        issues_to_add = @issues.select { |issue|
          if issue.milestone.nil?
            false
          else
            #check, that this milestone in tag list:
            milestone_is_tag = @all_tags.find { |tag|
              tag.name == issue.milestone.title
            }

            if milestone_is_tag.nil?
              false
            else
              issue.milestone.title == newer_tag_name
            end
          end
        }

        filtered_issues |= issues_to_add
      end

      self.create_log(filtered_pull_requests, filtered_issues, newer_tag_name, newer_tag_time, older_tag_name)

    end

    def delete_by_time(array, hash_key, newer_tag_time, older_tag = nil)

      older_tag_time = self.get_time_of_tag(older_tag)

      array.select { |req|
        if req[hash_key]
          t = Time.parse(req[hash_key]).utc

          if older_tag_time.nil?
            tag_in_range_old = true
          else
            tag_in_range_old = t > older_tag_time
          end

          tag_in_range_new = t <= newer_tag_time

          tag_in_range = (tag_in_range_old) && (tag_in_range_new)

          tag_in_range
        else
          false
        end
      }
    end

    # @param [Array] pull_requests
    # @param [Array] issues
    # @param [String] newer_tag_name
    # @param [String] newer_tag_time
    # @param [String] older_tag_name
    # @return [String]
    def create_log(pull_requests, issues, newer_tag_name, newer_tag_time, older_tag_name = nil)

      github_site = options[:github_site] || 'https://github.com'

      project_url = "#{github_site}/#{@options[:user]}/#{@options[:project]}"

      # Generate tag name and link
      log = "## [#{newer_tag_name}](#{project_url}/tree/#{newer_tag_name})\n"

      if @options[:compare_link] && older_tag_name
        # Generate compare link
        log += "[Full Changelog](#{project_url}/compare/#{older_tag_name}...#{newer_tag_name})\n"
      end

      #Generate date string:
      time_string = newer_tag_time.strftime @options[:format]
      log += "#### #{time_string}\n"

      if @options[:pulls]
        # Generate pull requests:
        pull_requests.each { |pull_request|
          merge = @generator.get_string_for_pull_request(pull_request)
          log += "- #{merge}"

        } if pull_requests
      end

      if @options[:issues]
        # Generate issues:
        if issues
          issues.sort! { |x, y|
            if x.labels.any? && y.labels.any?
              x.labels[0].name <=> y.labels[0].name
            else
              if x.labels.any?
                1
              else
                if y.labels.any?
                  -1
                else
                  0
                end
              end
            end
          }.reverse!
        end
        issues.each { |dict|
          is_bug = false
          is_enhancement = false
          dict.labels.each { |label|
            if label.name == 'bug'
              is_bug = true
            end
            if label.name == 'enhancement'
              is_enhancement = true
            end
          }

          intro = 'Closed issue'
          if is_bug
            intro = 'Fixed bug'
          end

          if is_enhancement
            intro = 'Implemented enhancement'
          end

          enc_string = @generator.encapsulate_string dict[:title]

          merge = "*#{intro}:* #{enc_string} [\\##{dict[:number]}](#{dict.html_url})\n\n"
          log += "- #{merge}"
        }
      end
      log
    end

    def get_time_of_tag(tag_name, tag_times_hash = @tag_times_hash)

      if tag_name.nil?
        return nil
      end

      if tag_times_hash[tag_name['name']]
        return @tag_times_hash[tag_name['name']]
      end

      github_git_data_commits_get = @github.git_data.commits.get @options[:user], @options[:project], tag_name['commit']['sha']
      time_string = github_git_data_commits_get['committer']['date']
      @tag_times_hash[tag_name['name']] = Time.parse(time_string)
    end

    def get_all_issues

      if @options[:verbose]
        print "Fetching closed issues...\r"
      end

      response = @github.issues.list user: @options[:user], repo: @options[:project], state: 'closed', filter: 'all', labels: nil

      issues = []
      page_i = 0
      count_pages = response.count_pages
      response.each_page do |page|
        page_i += PER_PAGE_NUMBER
        print "Fetching issues... #{page_i}/#{count_pages * PER_PAGE_NUMBER}\r"
        issues.concat(page)
      end

      print "                               \r"

      if @options[:verbose]
        puts "Received issues: #{issues.count}"
      end

      # remove pull request from issues:
      issues.select! { |x|
        x.pull_request == nil
      }

      filtered_issues = issues.select { |issue|
        #compare is there any labels from @options[:labels] array
        (issue.labels.map { |label| label.name } & @options[:labels]).any?
      }


      if @options[:add_issues_wo_labels]
        issues_wo_labels = issues.select {
          # add issues without any labels
            |issue| !issue.labels.map { |label| label.name }.any?
        }
        filtered_issues.concat(issues_wo_labels)
      end


      if @options[:verbose]
        puts "Filtered issues with labels #{@options[:labels]}#{@options[:add_issues_wo_labels] ? ' and w/o labels' : ''}: #{filtered_issues.count}"
      end

      filtered_issues

    end

    def fetch_event_for_issues(filtered_issues)
      if @options[:verbose]
        print "Fetching events for issues: 0/#{filtered_issues.count}\r"
      end

      # Async fetching events:
      threads = []

      i = 0
      filtered_issues.each { |issue|
        threads << Thread.new {
          obj = @github.issues.events.list user: @options[:user], repo: @options[:project], issue_number: issue['number']
          issue[:events] = obj.body
          print "Fetching events for issues: #{i+1}/#{filtered_issues.count}\r"
          i +=1
        }
      }
      threads.each { |thr| thr.join }

      if @options[:verbose]
        puts "Fetching events for issues: Done!"
      end
    end

  end

  if __FILE__ == $0
    GitHubChangelogGenerator::ChangelogGenerator.new.compund_changelog
  end

end
