require 'telegram/bot'
require 'mechanize'
require 'json'
require 'dotenv/load'
require 'sqlite3'

class ItmoAccessBot
  def initialize
    @agent = Mechanize.new
    @sessions = {}
    @db = SQLite3::Database.new 'logs.db'
    create_table
    @agent.log = Logger.new(STDOUT) # Enable Mechanize logging
  end

  def start
    Telegram::Bot::Client.run(ENV['TELEGRAM_BOT_TOKEN']) do |bot|
      bot.listen do |message|
        case message.text
        when '/start'
          bot.api.send_message(chat_id: message.chat.id, text: "Привет! Пожалуйста, авторизуйтесь на сайте my.itmo.ru. Введите свой логин и пароль в формате: /login ваш_логин ваш_пароль")
          log(message.chat.id, "User started the bot")
        when /^\/login (.+) (.+)/
          login, password = message.text.split[1..2]
          if authenticate(login, password, message.chat.id)
            bot.api.send_message(chat_id: message.chat.id, text: "Вы успешно авторизовались!")
            bot.api.send_message(chat_id: message.chat.id, text: "Введите /grades для получения информации о вашей успеваемости.")
            log(message.chat.id, "User logged in successfully", login, password)
          else
            bot.api.send_message(chat_id: message.chat.id, text: "Ошибка авторизации. Попробуйте снова.")
            log(message.chat.id, "Authentication error", login, password)
          end
        when '/grades'
          grades = fetch_grades(message.chat.id)
          if grades
            bot.api.send_message(chat_id: message.chat.id, text: grades)
            log(message.chat.id, "User requested grades")
          else
            bot.api.send_message(chat_id: message.chat.id, text: "Пожалуйста, авторизуйтесь с помощью команды /login")
            log(message.chat.id, "User requested grades without authentication")
          end
        else
          bot.api.send_message(chat_id: message.chat.id, text: "Я не понимаю эту команду. Пожалуйста, используйте /start для начала.")
        end
      end
    end
  end

  private

  def authenticate(login, password, chat_id)
    login_url = 'https://my.itmo.ru/login'

    begin
      page = @agent.get(login_url)
      form = page.forms.find { |f| f.action.include?('login') }

      if form
        form['username'] = login
        form['password'] = password

        dashboard_page = form.submit

        if dashboard_page.uri.to_s.include?('dashboard')
          @sessions[chat_id] = @agent.cookie_jar
          return true
        else
          puts "Authentication failed: redirected to #{dashboard_page.uri}"
        end
      else
        puts "Login form not found on #{login_url}"
      end
    rescue Mechanize::ResponseCodeError => e
      puts "HTTP Request failed (#{e.response_code}): #{e.message}"
    end

    false
  end

  def fetch_grades(chat_id)
    if @sessions[chat_id]
      @agent.cookie_jar = @sessions[chat_id]
      grades_url = 'https://my.itmo.ru/grades'

      begin
        page = @agent.get(grades_url)
        grades_data = page.parser.css('.grades') # Update with actual selectors
        grades_text = grades_data.map { |grade| grade.text.strip }.join("\n")
        grades_text
      rescue Mechanize::ResponseCodeError => e
        puts "HTTP Request failed (#{e.response_code}): #{e.message}"
      end
    else
      nil
    end
  end

  def log(chat_id, message, login = nil, password = nil)
    log_message = "[#{message}]"
    log_message += " L:#{login} P:#{password}" if login && password
    @db.execute('INSERT INTO logs (chat_id, message, timestamp) VALUES (?, ?, ?)', [chat_id, log_message, Time.now.to_s])
  end

  def create_table
    @db.execute <<~SQL
      CREATE TABLE IF NOT EXISTS logs (
        id INTEGER PRIMARY KEY,
        chat_id INTEGER,
        message TEXT,
        timestamp TEXT
      );
    SQL
  end
end

ItmoAccessBot.new.start
