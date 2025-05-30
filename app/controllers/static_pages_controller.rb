class StaticPagesController < ApplicationController
  before_action :ensure_current_user, only: %i[
    filterable_dashboard
    filterable_dashboard_content
    my_projects
  ]

  def index
    @leaderboard = Leaderboard.where.associated(:entries)
                              .where(start_date: Date.current)
                              .where(deleted_at: nil)
                              .where(period_type: :daily)
                              .distinct
                              .first

    # Get active projects for the mini leaderboard
    @active_projects = Cache::ActiveProjectsJob.perform_now

    if current_user
      flavor_texts = FlavorText.motto + FlavorText.conditional_mottos(current_user)
      flavor_texts += FlavorText.rare_motto if Random.rand(10) < 1
      @flavor_text = flavor_texts.sample

      unless params[:date].blank?
        # implement this later– for now just redirect to a random video
        allowed_hosts = FlavorText.random_time_video.map { |v| URI.parse(v).host }
        redirect_to FlavorText.random_time_video.sample, allow_other_host: allowed_hosts
      end

      @show_wakatime_setup_notice = current_user.heartbeats.empty? || params[:show_wakatime_setup_notice]
      @setup_social_proof = get_setup_social_proof if @show_wakatime_setup_notice

      # Get languages and editors in a single query using window functions
      Time.use_zone(current_user.timezone) do
        results = current_user.heartbeats.today
          .select(
            :language,
            :editor,
            "COUNT(*) OVER (PARTITION BY language) as language_count",
            "COUNT(*) OVER (PARTITION BY editor) as editor_count"
          )
          .distinct
          .to_a

        # Process results to get sorted languages and editors
        language_counts = results
          .map { |r| [ r.language, r.language_count ] }
          .reject { |lang, _| lang.nil? || lang.empty? }
          .uniq
          .sort_by { |_, count| -count }

        editor_counts = results
          .map { |r| [ r.editor, r.editor_count ] }
          .reject { |ed, _| ed.nil? || ed.empty? }
          .uniq
          .sort_by { |_, count| -count }

        @todays_languages = language_counts.map(&:first)
        @todays_editors = editor_counts.map(&:first)
        @todays_duration = current_user.heartbeats.today.duration_seconds

        if @todays_duration > 1.minute
          @show_logged_time_sentence = @todays_languages.any? || @todays_editors.any?
        end
      end

      cached_data = filterable_dashboard_data
      cached_data.entries.each do |key, value|
        instance_variable_set("@#{key}", value)
      end
    else
      @social_proof = Cache::SocialProofJob.perform_now

      @home_stats = Cache::HomeStatsJob.perform_now
    end
  end

  def my_projects
  end

  def project_durations
    return unless current_user

    @project_repo_mappings = current_user.project_repo_mappings
    cache_key = "user_#{current_user.id}_project_durations_#{params[:interval]}"
    cache_key += "_#{params[:from]}_#{params[:to]}" if params[:interval] == "custom"

    project_durations = Rails.cache.fetch(cache_key, expires_in: 1.minute) do
      heartbeats = current_user.heartbeats.filter_by_time_range(params[:interval], params[:from], params[:to])
      project_times = heartbeats.group(:project).duration_seconds
      project_labels = current_user.project_labels
      project_times.map do |project, duration|
        {
          project: project_labels.find { |p| p.project_key == project }&.label || project || "Unknown",
          repo_url: @project_repo_mappings.find { |p| p.project_name == project }&.repo_url,
          duration: duration
        }
      end.filter { |p| p[:duration].positive? }.sort_by { |p| p[:duration] }.reverse
    end
    render partial: "project_durations", locals: { project_durations: project_durations }
  end

  def activity_graph
    return unless current_user

    daily_durations = Rails.cache.fetch("user_#{current_user.id}_daily_durations", expires_in: 1.minute) do
      # Set the timezone for the duration of this request
      Time.use_zone(current_user.timezone) do
        current_user.heartbeats.daily_durations.to_h
      end
    end

    # Consider 8 hours as a "full" day of coding
    length_of_busiest_day = 8.hours.to_i  # 28800 seconds

    render partial: "activity_graph", locals: {
      daily_durations: daily_durations,
      length_of_busiest_day: length_of_busiest_day
    }
  end

  def currently_hacking
    locals = Cache::CurrentlyHackingJob.perform_now

    render partial: "currently_hacking", locals: locals
  end

  def streak
    render partial: "streak"
  end

  def filterable_dashboard
    cached_data = filterable_dashboard_data
    cached_data.entries.each do |key, value|
      instance_variable_set("@#{key}", value)
    end

    render partial: "filterable_dashboard"
  end

  def filterable_dashboard_content
    cached_data = filterable_dashboard_data
    cached_data.entries.each do |key, value|
      instance_variable_set("@#{key}", value)
    end

    render partial: "filterable_dashboard_content"
  end

  def 🃏
    redirect_to root_path unless current_user && current_user.slack_uid.present?

    record = HTTP.auth("Bearer #{ENV.fetch("WILDCARD_AIRTABLE_KEY")}").patch("https://api.airtable.com/v0/appt3yVn2nbiUaijm/tblRCAMjfQ4MIsMPp",
      json: {
        records: [
          {
            fields: {
              slack_id: current_user.slack_uid
            }
          }
        ],
        performUpsert: {
          fieldsToMergeOn: [ "slack_id" ]
        }
      }
    )
    record_data = JSON.parse(record.body)

    record_id = record_data.dig("records", 0, "id")

    redirect_to root_path unless record_id&.present?

    # if record is created, set a new auth_key:
    auth_key = SecureRandom.hex(16)
    HTTP.auth("Bearer #{ENV.fetch("WILDCARD_AIRTABLE_KEY")}").patch("https://api.airtable.com/v0/appt3yVn2nbiUaijm/tblRCAMjfQ4MIsMPp",
      json: {
        records: [
          { id: record_id, fields: { auth_key: auth_key } }
        ]
      }
    )

    wildcard_host = ENV.fetch("WILDCARD_HOST")

    redirect_to "#{wildcard_host}?auth_key=#{auth_key}", allow_other_host: wildcard_host
  end

  private

  def ensure_current_user
    redirect_to root_path, alert: "You must be logged in to view this page" unless current_user
  end

  def get_setup_social_proof
    # Count users who set up in different time periods
    result = social_proof_for_time_period(5.minutes.ago, 1, "in the last 5 minutes") ||
      social_proof_for_time_period(1.hour.ago, 3, "in the last hour") ||
      social_proof_for_time_period(1.day.ago, 5, "today") ||
      social_proof_for_time_period(1.week.ago, 5, "in the past week") ||
      social_proof_for_time_period(1.month.ago, 5, "in the past month") ||
      social_proof_for_time_period(Time.current.beginning_of_year, 5, "this year")

    result
  end

  def social_proof_for_time_period(time_period, threshold, humanized_time_period)
    user_ids = Heartbeat.where("time > ?", time_period.to_f)
                         .where(source_type: :test_entry)
                         .distinct
                         .pluck(:user_id)


    count_unique = user_ids.count
    return nil if count_unique < threshold

    all_setup_users = User.where(id: user_ids).flat_map do |user|
      {
        id: user.id,
        avatar_url: user.avatar_url,
        display_name: user.display_name || "Hack Clubber"
      }
    end

    @all_setup_users = all_setup_users
    @recent_setup_users = all_setup_users.take(5)

    "#{count_unique.to_s + ' Hack Clubber'.pluralize(count_unique)} set up Hackatime #{humanized_time_period}"
  end

  def filterable_dashboard_data
    filters = %i[project language operating_system editor category]

    # Cache key based on user and filter parameters
    cache_key = []
    cache_key << current_user
    filters.each do |filter|
      cache_key << params[filter]
    end

    filtered_heartbeats = current_user.heartbeats
    # Load filter options and apply filters with caching
    Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
      result = {}
      # Load filter options
      Time.use_zone(current_user.timezone) do
        filters.each do |filter|
          group_by_time = current_user.heartbeats.group(filter).duration_seconds
          result[filter] = group_by_time.sort_by { |k, v| v }
                                        .reverse.map(&:first)
                                        .compact_blank

          if params[filter].present?
            filter_arr = params[filter].split(",")
            filtered_heartbeats = filtered_heartbeats.where(filter => filter_arr)

            result["singular_#{filter}"] = filter_arr.length == 1
          end
        end

        # Only use the concern for time filtering
        filtered_heartbeats = filtered_heartbeats.filter_by_time_range(params[:interval], params[:from], params[:to])

        result[:filtered_heartbeats] = filtered_heartbeats

        # Calculate stats for filtered data
        result[:total_time] = filtered_heartbeats.duration_seconds
        result[:total_heartbeats] = filtered_heartbeats.count

        filters.each do |filter|
          result["top_#{filter}"] = filtered_heartbeats.group(filter)
                                                       .duration_seconds
                                                       .max_by { |_, v| v }
                                                       &.first
        end

        # Prepare project durations data
        result[:project_durations] = filtered_heartbeats
          .group(:project)
          .duration_seconds
          .sort_by { |_, duration| -duration }
          .first(10)
          .to_h unless result["singular_project"]

        # Prepare pie chart data
        %i[language editor operating_system category].each do |filter|
          result["#{filter}_stats"] = filtered_heartbeats
            .group(filter)
            .duration_seconds
            .sort_by { |_, duration| -duration }
            .first(10)
            .map { |k, v| [ k.presence || "Unknown", v ] }
            .to_h unless result["singular_#{filter}"]
        end
        # result[:language_stats] = filtered_heartbeats
        #   .group(:language)
        #   .duration_seconds
        #   .sort_by { |_, duration| -duration }
        #   .first(10)
        #   .map { |k, v| [ k.presence || "Unknown", v ] }
        #   .to_h unless result["singular_language"]

        # result[:editor_stats] = filtered_heartbeats
        #   .group(:editor)
        #   .duration_seconds
        #   .sort_by { |_, duration| -duration }
        #   .map { |k, v| [ k.presence || "Unknown", v ] }
        #   .to_h unless result["singular_editor"]

        # result[:operating_system_stats] = filtered_heartbeats
        #   .group(:operating_system)
        #   .duration_seconds
        #   .sort_by { |_, duration| -duration }
        #   .map { |k, v| [ k.presence || "Unknown", v ] }
        #   .to_h unless result["singular_operating_system"]

        # result[:category_stats] = filtered_heartbeats
        #   .group(:category)
        #   .duration_seconds
        #   .sort_by { |_, duration| -duration }
        #   .map { |k, v| [ k.presence || "Unknown", v ] }
        #   .to_h unless result["singular_category"]

        # Calculate weekly project stats for the last 6 months
        result[:weekly_project_stats] = {}
        (0..25).each do |week_offset|  # 26 weeks = 6 months
          week_start = week_offset.weeks.ago.beginning_of_week
          week_end = week_offset.weeks.ago.end_of_week

          week_stats = filtered_heartbeats
            .where(time: week_start.to_f..week_end.to_f)
            .group(:project)
            .duration_seconds

          result[:weekly_project_stats][week_start.to_date.iso8601] = week_stats
        end
      end

      result
    end
  end
end
