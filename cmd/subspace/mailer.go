package main

import (
	"bytes"
	"fmt"
	"math/rand"
	"net"
	"strings"
	"text/template"

	humanize "github.com/dustin/go-humanize"
	gomail "gopkg.in/gomail.v2"
)

type Mailer struct{}

func NewMailer() *Mailer {
	return &Mailer{}
}

func (m *Mailer) Forgot(email, secret string) error {
	subject := "Password reset link"

	params := struct {
		HTTPHost string
		Email    string
		Secret   string
	}{
		httpHost,
		email,
		secret,
	}
	return m.sendmail("forgot.html", email, subject, params)
}

func (m *Mailer) sendmail(tmpl, to, subject string, data interface{}) error {
	body, err := m.Render(tmpl, data)
	if err != nil {
		return err
	}

	cfg := config.FindInfo().Mail

	from := cfg.From
	server := cfg.Server
	port := cfg.Port
	username := cfg.Username
	password := cfg.Password

	if from == "" {
		from = fmt.Sprintf("Subspace <subspace@%s>", httpHost)
	}

	if server == "" {
		addrs, err := net.LookupMX(strings.Split(to, "@")[1])
		if err != nil || len(addrs) == 0 {
			return err
		}
		server = strings.TrimSuffix(addrs[rand.Intn(len(addrs))].Host, ".")
		port = 25
	}

	d := gomail.NewDialer(server, port, username, password)
	s, err := d.Dial()
	if err != nil {
		return err
	}
	logger.Infof("sendmail from %q to %q %q via %s:%d", from, to, subject, server, port)

	msg := gomail.NewMessage()
	msg.SetHeader("From", from)
	msg.SetHeader("To", to)
	msg.SetHeader("Subject", subject)
	msg.SetBody("text/html", body)

	if err := gomail.Send(s, msg); err != nil {
		return fmt.Errorf("failed sending email: %s", err)
	}
	return nil
}

func (m *Mailer) Render(template_filename string, data interface{}) (string, error) {
	tpl_path := fmt.Sprintf("email/%s", template_filename)
	t, err := template.New(template_filename).Funcs(template.FuncMap{
		"time": humanize.Time,
	}).ParseFS(Assets, tpl_path, "templates/header.html", "templates/footer.html")
	if err != nil {
		logger.Errorf("failed parsing template: %s", tpl_path)
		return "", err
	}
	var b bytes.Buffer
	if err := t.Execute(&b, data); err != nil {
		return "", err
	}
	return b.String(), nil
}
