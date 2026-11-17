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
  ['תוכן וסושיאל', /social media|content (market|creat|strateg|manager|specialist|writer|lead|coordinator)|creative content|copywriter|storyteller|סושיאל|מדיה חברתית|(?:מנהל|יוצר|עורכ|כותב).{0,5} תוכן|יצירת תוכן/i, 'תוכן, עיצוב ושיווק דיגיטלי'],
  ['שיווק ותפעול', /employer brand|מיתוג מעסיק|marketing (coordinator|operations|associate|specialist)|(?:רכז|תיאום).{0,5} שיווק/i, 'תיאום שיווקי ועבודה עם צוותים שונים'],
  ['תפעול משאבי אנוש', /hr (operations|coordinator|administrator)|human resources (operations|coordinator)/i, 'תפעול חוויית עובד ועבודה עם צוותים שונים'],
  ['הסברה ותקשורת ציבורית', /\b(?:hasbara|public diplomacy|public affairs|public communications?|communications and advocacy)\b|הסברה|דוברות/i, 'הסברה, כתיבת תוכן ותקשורת עם קהלים']
].freeze
ISRAEL = /\b(israel|tel[ -]aviv|ramat gan|herzliya|ra['’]?anana|kfar saba|petah tikva|bnei brak|holon|givatayim|hod hasharon|netanya|jerusalem|haifa|rehovot|yokneam)\b|ישראל|תל אביב|הרצליה|רעננה|רמת גן|כפר סבא/i
CENTRAL = /tel[ -]aviv|ramat gan|herzliya|ra['’]?anana|kfar saba|petah tikva|givatayim|תל אביב|הרצליה|רעננה|רמת גן|כפר סבא/i
GENERAL_TITLE = /\b(?:marketing|communications?|brand|creative|community|office|workplaces?|people|hr|human resources|operations|team coordinator|team administrator|administrative coordinator|program coordinator)\b|שיווק|תפעול|תקשורת|משאבי אנוש|אדמיניסטרציה|רכז.{0,3} צוות/i
RESPONSIBILITY = /\b(?:manage|coordinate|lead|create|produce|write|develop|own|organize|run|drive|support|build|plan|oversee|contribute|collaborate|execute)\b|ניהול|תיאום|יצירת|הובלת/i
DUTY_RULES = [
  [6, /public diplomacy|public awareness campaigns|public advocacy campaigns|hasbara|הסברה|דוברות/i],
  [1, /internal communications?|employee communications?|employee newsletters?|תקשורת פנים/i],
  [0, /employee (experience|engagement|welfare|lifecycle|events|services|wellbeing)|(?:company|office|team|employee|internal) events|team[ -]building|(?:workplace|company|organizational) culture|culture initiatives|onboarding|offboarding|חווי[יי]?ת עובד|רווחת עובד|אירועי (?:חברה|עובדים|צוות)|קליטת עובדים|תרבות ארגונית/i],
  [3, /social media|content creation|content strategy|website content|creative content|storytelling|copywriting|newsletters|סושיאל|יצירת תוכן/i],
  [4, /employer brand|marketing operations|(?:coordinate|manage|create|execute) marketing campaigns|marketing automation|מיתוג מעסיק|תפעול שיווק/i],
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

def role_identity(title)
  normalize(title).sub(/\s+(?:part time|full time)\z/, '').gsub(/\band\s+/, '')
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
  when /maternity[- ](?:leave|cover|replacement)|parental leave cover|חופשת לידה|חל["״']?ד/i then 'החלפה לחופשת לידה'
  when /fixed[ -]term|\b\d+[ -]months? (contract|position)|חוזה לתקופה/i then 'חוזה לתקופה מוגדרת'
  when /\b(?:temporary|temp)\b|משרה זמנית|החלפה זמנית|תפקיד זמני/i then 'זמנית (Temp)'
  when /\bpermanent (?:role|position|contract|employment)\b|משרה קבועה/i then 'קבועה'
  when /\bfreelance\b/i then 'פרויקט / פרילנס'
  end
end

PERSONAL_ASSISTANT_ROLE = %r{\b(?:personal assistant|personal aide|p\.?a\.?\s+to|(?:office manager|assistant)\s*(?:[/&+-]|and)\s*p\.?a\.?(?:\s|$)|secretary(?: and)? personal assistant)\b|עוזר(?:ת|[/.\s]ת)?\s+אישי(?:ת|[/.\s]ת)?}i
JOB_NOTICE_PATTERNS = {
  'travel' => %r{\b(?:travel (?:arrangements|coordination|logistics|booking|scheduling)|(?:book(?:s|ed|ing)?|(?:coordinat|arrang|manag|organiz|organis)(?:e|es|ed|ing))\s+(?:(?:business|corporate|executive|international|domestic)\s+)?(?:travel|flights|trips))\b|(?:תיאום|ניהול|ארגון|הזמנת)\s+(?:של\s+)?(?:נסיעות|טיסות)}i,
  'ceo_calendar' => %r{\b(?:ceo(?:['’]s)? (?:calendar|diary|schedule)|(?:calendar|diary|schedule) (?:management )?(?:for|of) (?:the )?ceo)\b|(?:ניהול|תיאום)\s+(?:ה)?יומן\s+(?:של\s+)?(?:ה)?מנכ[״"׳']?ל}i,
  'personal_support' => %r{\b(?:personal (?:support|assistance|errands|appointments|tasks)|support (?:the )?(?:ceo|executives?|leadership) (?:with|on) personal)\b|תמיכה אישית|סיוע אישי|סידורים אישיים|משימות אישיות}i,
  'portfolio' => %r{\b(?:(?:submit|include|provide|attach|share|send|link to)\s+(?:(?:a|your|an)\s+)?(?:creative\s+|design\s+|writing\s+)?portfolio|portfolio\s+(?:is\s+)?(?:required|mandatory)|(?:creative|design|writing) portfolio|portfolio of (?:your )?(?:work|writing|designs?))\b|תיק עבודות|דוגמאות כתיבה}i
}.freeze

def job_from(raw, source, timestamp, excluded = Hash.new(0))
  title = raw.fetch('title').gsub(/[[:space:]]+/, ' ').strip
  rule = RULES.find { |_, pattern, _| title.match?(pattern) }
  exclusion = if title.match?(PERSONAL_ASSISTANT_ROLE) ||
                 (title.match?(/executive assistant|cto office|ceo office/i) && !rule.equal?(RULES[2]))
                'assistant_title'
              elsif title.match?(/\bproduct market(?:ing|er)\b|שיווק מוצר/i)
                'product_marketing'
              elsif !rule && !title.match?(GENERAL_TITLE)
                'unrelated_title'
              end
  if exclusion
    excluded[exclusion] += 1
    return
  end

  ashby = source['provider'] == 'Ashby'
  location = ashby ? raw['location'] : raw.dig('location', 'name')
  location = Array(raw['secondaryLocations']).find { |item| item.to_s.match?(ISRAEL) } unless location.to_s.match?(ISRAEL)
  unless location.to_s.match?(ISRAEL)
    excluded['location_outside_israel_or_unknown'] += 1
    return
  end
  url = normalized_url(raw[ashby ? 'jobUrl' : 'absolute_url'])
  unless url
    excluded['invalid_posting_url'] += 1
    return
  end
  if raw['isListed'] == false
    excluded['not_publicly_listed'] += 1
    return
  end

  lines = clean(raw[ashby ? 'descriptionHtml' : 'content'])
  if lines.any? { |line| line.match?(/\b(?:role|position|work|serve)\s+(?:is\s+)?(?:primarily\s+)?as\s+(?:an?\s+)?personal assistant\b|\b(?:looking|seeking|hiring)\s+for\s+(?:an?\s+)?personal assistant\b|התפקיד\s+הוא\s+עוזר(?:ת)?\s+אישי(?:ת)?/i) }
    excluded['personal_assistant_role'] += 1
    return
  end
  posting_text = [title, *lines].join(' ')
  notices = JOB_NOTICE_PATTERNS.keys.select { |notice| posting_text.match?(JOB_NOTICE_PATTERNS.fetch(notice)) }
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
    unless matched || office_operations
      excluded[rule ? 'no_relevant_office_duties' : 'no_relevant_duties'] += 1
      return
    end
    rule ||= RULES[matched.first]
  end
  role_lines = duties ? lines.drop(duties + 1).take(2) : lines.select { |line| line.match?(/\b(you will|you.ll|responsible for)\b/i) }.take(2)
  role_lines = [evidence, *role_lines].compact.uniq.take(2)
  role_lines = role_lines.reject { |line| line.match?(/\Awhy you.ll love/i) }
  work_schedule = raw['employmentType']
  work_schedule ||= title[/\b(?:part|full)[ -]time\b/i]
  condition = lines.find { |line| line.match?(/(?:on-site|onsite|working from the office|office presence).*(?:days a week|days per week)/i) }
  identity = normalize(source.fetch('company')) + '/' + role_identity(title)
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
    'notices' => notices,
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
          elsif source.fetch('provider') == 'Lever'
            "https://api.lever.co/v0/postings/#{board}?mode=json"
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
  if source.fetch('provider') == 'Lever'
    raise 'Invalid Lever feed' unless payload.is_a?(Array)
    return payload.map do |posting|
      categories = posting.fetch('categories')
      sections = Array(posting['lists']).map do |section|
        "<p>#{CGI.escapeHTML(section.fetch('text', ''))}</p>#{section['content']}"
      end
      {
        'id' => posting.fetch('id'),
        'title' => posting.fetch('text'),
        'location' => { 'name' => categories['location'] },
        'secondaryLocations' => categories['allLocations'],
        'absolute_url' => posting.fetch('hostedUrl'),
        'content' => [posting['description'], *sections].compact.join("\n"),
        'employmentType' => categories['commitment']
      }
    end
  end
  jobs = payload.fetch('jobs')
  raise 'Invalid jobs feed' unless jobs.is_a?(Array)
  jobs
end

def discover(sources, previous, timestamp)
  jobs = previous.fetch('jobs', []).each_with_object({}) { |job, index| index[job.fetch('id')] = job }
  seen_urls = {}
  seen_roles = {}
  jobs.each_value do |job|
    url = normalized_url(job['url'])
    seen_urls[url] ||= job['id'] if url
    seen_roles[[normalize(job['company']), role_identity(job['title'])]] ||= job['id']
  end
  matched_ids = {}
  status = {}
  sources.each do |source|
    key = source.values_at('provider', 'board').join('/')
    begin
      description = source['description']
      if !description.is_a?(String) || description.strip.empty? || description.strip == source['industry'].to_s.strip
        raise ArgumentError, 'Source requires a company description beyond its industry label'
      end
      raw = read_board(source)
      excluded = Hash.new(0)
      live = raw.map { |item| job_from(item, source, timestamp, excluded) }.compact
      duplicates = 0
      added = 0
      jobs.each_value do |job|
        job['active'] = false if job.values_at('source', 'board').join('/') == key && !matched_ids[job['id']]
      end
      live.each do |job|
        role = [normalize(job['company']), role_identity(job['title'])]
        id = seen_urls[job['url']] || seen_roles[role] || job['id']
        seen_urls[job['url']] = id
        seen_roles[role] = id
        if matched_ids[id]
          duplicates += 1
          next
        end
        prior = jobs[id]
        if prior
          duplicates += 1
        else
          added += 1
        end
        job['id'] = id
        job['discoveredAt'] = prior['discoveredAt'] if prior
        jobs[id] = job
        matched_ids[id] = true
      end
      status[key] = {
        'success' => true, 'read' => raw.size, 'matched' => live.size,
        'duplicates' => duplicates, 'added' => added, 'excluded' => excluded
      }
      puts "#{key}: #{JSON.generate(status[key])}"
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
