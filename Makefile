.PHONY: install 

install:
	@echo "Installing SpinDoctor..."
	install -Dm755 spindoctor /usr/local/sbin/spindoctor
	install -Dm755 spindoctor-loadtest /usr/local/sbin/spindoctor-loadtest
	install -Dm644 config/qnap-ts-453d.json /etc/spindoctor.json
	install -Dm644 systemd/spindoctor.service /etc/systemd/system/spindoctor.service
	install -Dm644 udev/99-spindoctor-pwm.rules /etc/udev/rules.d/99-spindoctor-pwm.rules
	systemctl daemon-reload
	systemctl enable spindoctor.service

