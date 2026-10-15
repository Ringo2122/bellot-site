# Письма личного кабинета (Supabase Auth, отправка через Resend): темы и тексты — по-русски, с логотипом и кодом.
# python3 supabase/email-templates.py → JSON для PATCH /v1/projects/<ref>/config/auth (Management API). 15.10.2026
import json
def body(title, lead, note, pre):
    # строка-превью: её показывают почтовые программы под темой и в уведомлении; в открытом письме не видна
    return f"""<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:#ffffff;opacity:0">{pre}{"&#8203;&nbsp;" * 60}</div>
<div style="font-family:Arial,Helvetica,sans-serif;max-width:480px;margin:0 auto;padding:24px 20px;color:#18181b">
  <img src="https://monitorg.by/logo-mail.png" width="200" height="63" alt="МониТорг" style="display:block;border:0;margin:0 0 22px">
  <h2 style="margin:0 0 12px;font-size:20px">{title}</h2>
  <p style="margin:0 0 16px;font-size:15px;line-height:1.5">{lead}</p>
  <p style="margin:0 0 16px;font-size:32px;font-weight:700;letter-spacing:6px;color:#041c33">{{{{ .Token }}}}</p>
  <p style="margin:0 0 24px;font-size:14px;line-height:1.5;color:#52525b">{note}</p>
  <p style="margin:0;padding-top:16px;border-top:1px solid #e4e4e7;font-size:12px;line-height:1.5;color:#71717a">МониТорг — агрегатор торгов по имуществу должников Беларуси. <a href="https://monitorg.by" style="color:#f4511e">monitorg.by</a><br>Письмо отправлено автоматически, отвечать на него не нужно.</p>
</div>"""
ign = "Код действует 1 час. Если вы этого не запрашивали, просто проигнорируйте письмо — без кода ничего не изменится."
cfg = {
  "mailer_subjects_confirmation": "{{ .Token }} — код подтверждения почты на МониТорге",
  "mailer_templates_confirmation_content": body("Подтвердите почту", "Вы регистрируетесь в личном кабинете МониТорга. Введите этот код на сайте, чтобы подтвердить адрес почты:", "Код действует 1 час. Если вы не регистрировались на monitorg.by, просто проигнорируйте письмо.", "Ваш код: {{ .Token }}"),
  "mailer_subjects_recovery": "Смена пароля на МониТорге",
  "mailer_templates_recovery_content": body("Смена пароля", "Вы запросили смену пароля в личном кабинете МониТорга. Введите этот код на сайте и задайте новый пароль:", ign, "Вы запросили смену пароля. Код — внутри письма"),
  "mailer_subjects_email_change": "Подтверждение новой почты на МониТорге",
  "mailer_templates_email_change_content": body("Подтвердите новую почту", "Вы меняете адрес почты личного кабинета МониТорга на {{ .NewEmail }}. Введите этот код на сайте:", ign, "Код подтверждения новой почты — внутри письма"),
  "mailer_subjects_reauthentication": "Код подтверждения на МониТорге",
  "mailer_templates_reauthentication_content": body("Код подтверждения", "Введите этот код на сайте МониТорга, чтобы подтвердить действие:", ign, "Код подтверждения — внутри письма"),
  "mailer_subjects_magic_link": "Вход в личный кабинет МониТорга",
  "mailer_templates_magic_link_content": body("Вход в личный кабинет", "Введите этот код на сайте МониТорга, чтобы войти в личный кабинет:", ign, "Код для входа — внутри письма"),
  "mailer_subjects_invite": "Приглашение в личный кабинет МониТорга",
  "mailer_templates_invite_content": """<div style="font-family:Arial,Helvetica,sans-serif;max-width:480px;margin:0 auto;padding:24px 20px;color:#18181b">
  <img src="https://monitorg.by/logo-mail.png" width="200" height="63" alt="МониТорг" style="display:block;border:0;margin:0 0 22px">
  <h2 style="margin:0 0 12px;font-size:20px">Вас пригласили в МониТорг</h2>
  <p style="margin:0 0 20px;font-size:15px;line-height:1.5">Чтобы принять приглашение и создать личный кабинет, нажмите кнопку:</p>
  <p style="margin:0 0 24px"><a href="{{ .ConfirmationURL }}" style="display:inline-block;background:#f4511e;color:#fff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:8px">Принять приглашение</a></p>
  <p style="margin:0;padding-top:16px;border-top:1px solid #e4e4e7;font-size:12px;color:#71717a">МониТорг — агрегатор торгов по имуществу должников Беларуси. <a href="https://monitorg.by" style="color:#f4511e">monitorg.by</a></p>
</div>""",
}
print(json.dumps(cfg, ensure_ascii=False))
