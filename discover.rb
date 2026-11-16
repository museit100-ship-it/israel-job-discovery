require 'cgi'
require 'digest'
require 'json'
require 'net/http'
require 'time'
require 'timeout'
require 'uri'

ROOT = __dir__
DiscoveryDeadline = Class.new(StandardError)
RULES = [
  ['חוויית עובד ותרבות', /employee (experience|engagement|welfare)|people (experience|operations|ops)|workplace experience|organizational culture|חוויית עובד|רווחת עובד/i, 'חוויית עובד, מעורבות עובדים ותפעול'],
  ['תקשורת פנים־ארגונית', /internal (comms|communications)|employee communications|תקשורת פנים/i, 'תקשורת פנים־ארגונית וכתיבת תוכן'],
  ['ניהול משרד ותפעול מקום העבודה', /office (manager|management|coordination|coordinator|admin(?:istrator)?|operations)|workplace (manager|coordination|coordinator|operations|services)|(?:מנהל|רכז|מתאמ).{0,6} משרד|תיאום משרד/i, 'תפעול מקום העבודה ותיאום יוזמות'],
  ['תוכן וסושיאל', /social media|content (market|creat|strateg|manager|specialist|writer|lead|coordinator)|creative content|copywriter|storyteller|סושיאל|מנהל.{0,3} תוכן/i, 'תוכן, עיצוב ושיווק דיגיטלי'],
  ['שיווק ותפעול', /marketing (coordinator|operations|associate|specialist)|רכז.{0,3} שיווק/i, 'תיאום שיווקי ועבודה עם צוותים שונים'],
  ['תפעול משאבי אנוש', /hr (operations|coordinator|administrator)|human resources (operations|coordinator)/i, 'תפעול חוויית עובד ועבודה עם צוותים שונים'],
  ['הסברה ותקשורת ציבורית', /\b(?:hasbara|public diplomacy|public affairs|public communications?|communications and advocacy)\b|הסברה|דוברות/i, 'הסברה, כתיבת תוכן ותקשורת עם קהלים']
].freeze
ISRAEL = /\b(israel|tel[ -]aviv|ramat gan|herzliya|ra['’]?anana|kfar saba|petah tikva|bnei brak|holon|givatayim|hod hasharon|netanya|jerusalem|haifa|rehovot|yokneam)\b|ישראל|תל אביב|הרצליה|רעננה|רמת גן|כפר סבא/i
CENTRAL = /tel[ -]aviv|ramat gan|herzliya|ra['’]?anana|kfar saba|petah tikva|givatayim|תל אביב|הרצליה|רעננה|רמת גן|כפר סבא/i
GENERAL_TITLE = /\b(?:marketing|communications?|brand|creative|community|office|workplaces?|people|hr|human resources|operations)\b|שיווק|תפעול|תקשורת|משאבי אנוש/i
RESPONSIBILITY = /\b(?:manage|coordinate|lead|create|produce|write|develop|own|organize|run|drive|support|build|plan|oversee|contribute|collaborate|execute)\b|ניהול|תיאום|יצירת|הובלת/i
DUTY_RULES = [
  [6, /public diplomacy|public awareness campaigns|public advocacy campaigns|hasbara|הסברה|דוברות/i],
  [1, /internal communications?|employee communications?|employee newsletters?|תקשורת פנים/i],
  [0, /employee (experience|engagement|welfare|lifecycle|events|services)|culture initiatives|onboarding and offboarding|חוויית עובד|רווחת עובדים/i],
  [3, /social media|content creation|content strategy|website content|creative content|storytelling|copywriting|newsletters|סושיאל|יצירת תוכן/i],
  [4, /marketing operations|coordinate marketing campaigns|marketing automation|תפעול שיווק/i],
  [5, /people operations|hr operations|HRIS|משאבי אנוש/i]
].freeze

def clean(html)
  text = CGI.unescapeHTML(html.to_s)
  text = text.gsub(%r{</(?:p|div|li|h[1-6])>|<br\s*/?>}i, "\n")
  text = CGI.unescapeHTML(text.gsub(/<[^>]*>/, ' ').gsub('&nbsp;', ' '))
  text.lines.map { |line| line.gsub(/[[:space:]]+/, ' ').strip }.reject(&:empty?)
end

def normalize(value)
  value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^[:alnum:]]+/, ' ').strip
end

def normalized_url(value)
  url = URI.parse(value.to_s)
  return unless url.is_a?(URI::HTTPS) && url.host && !url.userinfo

  params = URI.decode_www_form(url.query.to_s).reject do |key, _|
    key.match?(/\A(?:utm_.*|gh_src|source|ref|fbclid|gclid)\z/i)
  end
  url.query = params.empty? ? nil : URI.encode_www_form(params.sort)
  url.fragment = nil
  url.host = url.host.downcase
  url.host = 'job-boards.greenhouse.io' if url.host == 'boards.greenhouse.io'
  url.path = url.path.sub(%r{/+\z}, '')
  url.to_s
rescue URI::InvalidURIError, ArgumentError
  nil
end

def employment_type(text)
  case text
  when /maternity (leave|cover|replacement)|חופשת לידה/i then 'החלפה לחופשת לידה'
  when /fixed[ -]term|\b\d+[ -]months? (contract|position)|חוזה לתקופה/i then 'חוזה לתקופה מוגדרת'
  when /\btemporary\b|משרה זמנית/i then 'זמנית (Temp)'
  when /\bpermanent (?:role|position|contract|employment)\b|משרה קבועה/i then 'קבועה'
  when /\bfreelance\b/i then 'פרויקט / פרילנס'
  end
end

def job_from(raw, source, timestamp)
  title = raw.fetch('title').gsub(/[[:space:]]+/, ' ').strip
  return if title.match?(/personal assistant|executive assistant|cto office|ceo office/i)
  return if title.match?(/\bproduct market(?:ing|er)\b|שיווק מוצר/i)
  rule = RULES.find { |_, pattern, _| title.match?(pattern) }
  return unless rule || title.match?(GENERAL_TITLE)

  ashby = source['provider'] == 'Ashby'
  location = ashby ? raw['location'] : raw.dig('location', 'name')
  location = Array(raw['secondaryLocations']).find { |item| item.to_s.match?(ISRAEL) } unless location.to_s.match?(ISRAEL)
  return unless location.to_s.match?(ISRAEL)
  url = normalized_url(raw[ashby ? 'jobUrl' : 'absolute_url'])
  return unless url

  return if ashby && raw['isListed'] == false

  lines = clean(raw[ashby ? 'descriptionHtml' : 'content'])
  requirements = lines.index { |line| line.match?(/\A(?:requirements|what you.ll bring|qualifications|what you bring|what you need|the ideal candidate should have|about you|דרישות)\b/i) }
  duties = lines.index { |line| line.match?(/\A(?:responsibilities|what you.ll do|what you will do|what will you be doing|your impact|תחומי אחריות)\b/i) }
  body = requirements ? lines.take(requirements) : lines
  evidence = nil
  inferred_from_description = rule.nil?
  if inferred_from_description || rule.equal?(RULES[2])
    candidates = body.select { |line| line.match?(RESPONSIBILITY) }
    matched = DUTY_RULES.find do |index, pattern|
      next false if rule && ![0, 1, 3].include?(index)
      next false if inferred_from_description && index == 5 && !title.match?(/\b(?:people|hr|human resources)\b/i)

      evidence = candidates.find { |line| line.match?(pattern) }
    end
    # Office titles can also fit through responsibility for vendors, facilities or office logistics.
    office_operations = rule.equal?(RULES[2]) && candidates.any? do |line|
      line.match?(/office logistics|office events|office supplies|facilities|vendor relationships|vendors|ספקים|לוגיסטיקה/i)
    end
    return unless matched || office_operations
    rule ||= RULES[matched.first]
  end
  role_lines = duties ? lines.drop(duties + 1).take(2) : lines.select { |line| line.match?(/\b(you will|you.ll|responsible for)\b/i) }.take(2)
  role_lines = [evidence, *role_lines].compact.uniq.take(2)
  role_lines = role_lines.reject { |line| line.match?(/\Awhy you.ll love/i) }
  work_schedule = raw['employmentType'] if ashby
  work_schedule ||= title[/\b(?:part|full)[ -]time\b/i]
  condition = lines.find { |line| line.match?(/(?:on-site|onsite|working from the office|office presence).*(?:days a week|days per week)/i) }
  identity = normalize(source.fetch('company')) + '/' + normalize(title)
  central = location.match?(CENTRAL)
  base_score = inferred_from_description ? 65 : 75
  score = base_score + (central ? 10 : 0)
  match_basis = inferred_from_description ? 'תחומי אחריות במודעה' : 'כותרת המשרה'
  {
    'id' => Digest::SHA256.hexdigest(identity)[0, 24], 'title' => title,
    'company' => source.fetch('company'), 'location' => location,
    'url' => url, 'source' => source.fetch('provider'), 'board' => source.fetch('board'),
    'sourceId' => raw['id'] || url,
    'discoveredAt' => timestamp, 'verifiedAt' => timestamp,
    'publishedAt' => raw[ashby ? 'publishedAt' : 'first_published'],
    'employmentType' => employment_type([title, *lines].join(' ')),
    'workSchedule' => work_schedule,
    'industry' => source.fetch('industry'), 'companyDescription' => source.fetch('description'),
    'website' => source.fetch('website'), 'category' => rule[0],
    'summary' => role_lines.map { |line| line[0, 260] }.join(' '),
    'requirements' => requirements ? lines.drop(requirements + 1).take(2).join(' ')[0, 450] : nil,
    'workCondition' => condition&.slice(0, 260),
    'score' => score, 'match' => "#{match_basis} מצביעים על זיקה לתחום #{rule[2]} (#{base_score} נקודות)#{central ? ' והמיקום במרכז (10 נקודות)' : ''}.",
    'active' => true
  }
end

def read_board(source)
  if ENV['JOB_DISCOVERY_FIXTURES']
    name = source.fetch('board') + '.json'
    payload = JSON.parse(File.read(File.join(ENV.fetch('JOB_DISCOVERY_FIXTURES'), name)))
  else
    board = URI.encode_www_form_component(source.fetch('board'))
    url = if source.fetch('provider') == 'Ashby'
            "https://api.ashbyhq.com/posting-api/job-board/#{board}"
          else
            "https://boards-api.greenhouse.io/v1/boards/#{board}/jobs?content=true"
          end
    uri = URI(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.max_retries = 0
      http.get(uri.request_uri, 'Accept' => 'application/json')
    end
    raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    payload = JSON.parse(response.body)
  end
  jobs = payload.fetch('jobs')
  raise 'Invalid jobs feed' unless jobs.is_a?(Array)
  jobs
end

def discover(sources, previous, timestamp)
  jobs = previous.fetch('jobs', []).each_with_object({}) { |job, index| index[job.fetch('id')] = job }
  seen_urls = jobs.values.to_h { |job| [job['url'], job['id']] }
  status = {}
  sources.each do |source|
    key = source.values_at('provider', 'board').join('/')
    begin
      raw = read_board(source)
      live = raw.map { |item| job_from(item, source, timestamp) }.compact
      jobs.each_value do |job|
        job['active'] = false if job.values_at('source', 'board').join('/') == key
      end
      live.each do |job|
        id = seen_urls.fetch(job['url'], job['id'])
        prior = jobs[id]
        job['id'] = id
        job['discoveredAt'] = prior['discoveredAt'] if prior
        jobs[id] = job
        seen_urls[job['url']] = id
      end
      status[key] = { 'success' => true, 'read' => raw.size, 'matched' => live.size }
      puts "#{key}: #{raw.size} postings, #{live.size} matched"
    rescue DiscoveryDeadline
      raise
    rescue StandardError => error
      warn "#{key}: #{error.class}: #{error.message}"
      status[key] = { 'success' => false, 'error' => "#{error.class}: #{error.message}" }
    end
  end

  successful = status.values.any? { |result| result['success'] }
  {
    'version' => 1, 'attemptedAt' => timestamp,
    'lastSuccessfulAt' => successful ? timestamp : previous['lastSuccessfulAt'],
    'sources' => status, 'jobs' => jobs.values.sort_by { |job| job.fetch('id') }
  }
end

def discovery_rpc(function, arguments)
  url = URI(ENV.fetch('SUPABASE_URL'))
  unless url.is_a?(URI::HTTPS) && url.host && !url.userinfo
    raise 'SUPABASE_URL must be an HTTPS URL'
  end
  url.path = "/rest/v1/rpc/#{function}"
  url.query = nil
  url.fragment = nil
  secret = ENV.fetch('SUPABASE_SECRET_KEY')
  headers = { 'apikey' => secret, 'Content-Type' => 'application/json' }
  headers['Authorization'] = "Bearer #{secret}" unless secret.start_with?('sb_secret_')

  response = Net::HTTP.start(url.host, url.port, use_ssl: true, open_timeout: 4,
                             read_timeout: 4, write_timeout: 4) do |http|
    http.max_retries = 0
    http.post(url.request_uri, JSON.generate(arguments), headers)
  end
  raise "Discovery database #{function}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end

def write_feed(output, result)
  temporary = "#{output}.#{Process.pid}.tmp"
  File.write(temporary, JSON.pretty_generate(result) + "\n")
  File.rename(temporary, output)
ensure
  File.delete(temporary) if temporary && File.exist?(temporary)
end

def run_discovery(output)
  fixtures = ENV['JOB_DISCOVERY_FIXTURES']
  trigger = ENV['GITHUB_EVENT_NAME'] == 'schedule' ? 'scheduled' : 'manual'
  unless fixtures
    run_id = discovery_rpc('claim_discovery_run', { 'p_trigger' => trigger })
    unless run_id
      puts 'Discovery skipped by the database execution guard.'
      return 0
    end
  end

  outcome = 'failed'
  details = {}
  begin
    # Leave time to report the outcome before the runner's hard stop.
    Timeout.timeout(9 * 60, DiscoveryDeadline) do
      sources = JSON.parse(File.read(File.join(ROOT, 'sources.json')))
      previous = File.exist?(output) ? JSON.parse(File.read(output)) : {}
      result = discover(sources, previous, Time.now.utc.iso8601)
      write_feed(output, result)
      details = { 'sources' => result.fetch('sources') }
      outcome = 'succeeded' if details.fetch('sources').values.all? { |source| source['success'] }
    end
  rescue DiscoveryDeadline
    outcome = 'timed_out'
    details = { 'error' => 'Discovery exceeded its execution window' }
  rescue StandardError => error
    details = { 'error' => "#{error.class}: #{error.message}" }
  ensure
    if run_id
      saved = discovery_rpc('finish_discovery_run', {
        'p_run_id' => run_id, 'p_outcome' => outcome, 'p_details' => details
      })
      raise 'The database did not record discovery completion' unless saved
    end
  end
  warn details['error'] if details['error']
  outcome == 'succeeded' ? 0 : 1
end

exit(run_discovery(ARGV.fetch(0, File.join(ROOT, 'jobs.json')))) if $PROGRAM_NAME == __FILE__
