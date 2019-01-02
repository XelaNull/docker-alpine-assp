# Create ASSP Docker Container
FROM alpine:3.8

ENV TZ=America/New_York
ENV MY_NAME=mail.yourdomain.com
ENV MAILADMIN=youremail@addresshere.com
ENV ASSP_PASS=YOUR-ASSP-PASSWORD-HERE
ENV SMTP_DESTINATION=mail.YOURMAILSMTPSERVER.com:25
ENV SMTP_DESTINATION_SSL=mail.YOURMAILSMTPSERVER.com:465
ENV ACCEPT_ALL_MAIL=your.ip.here|partial.ip.here
ENV RELAY_HOST=127.0.0.1:1025
ENV RELAY_PORT=2025
ENV ALLOW_RELAY_CON=your.ip.here|partial.ip.here
ENV DEFAULT_LOCALHOST=yourdomain.com
ENV SEND_HAM_INBOUND=ham.j2bgtj41o@yourdomain.com
ENV SEND_HAM_OUTBOUND=ham.j2bgtj41o@yourdomain.com
ENV POSTMASTER=postmaster@yourdomain.com
ENV LOCAL_DOMAINS=yourdomain.com|yourseconddomain.org
ENV MY_SERVER_RE=your.external.ip|your.internal.ip|mail.yourdomain.com
ENV NO_DELAY=@netflix.com

# Set the Alpine APK Repositories to use
RUN {  echo '@edge http://nl.alpinelinux.org/alpine/edge/main'; \
       echo '@testing http://nl.alpinelinux.org/alpine/edge/testing'; \
    } | tee >> /etc/apk/repositories

# Set the Timezone of the image to be built
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Ensure we have the latest packages available from the APK REPO
RUN apk update && apk upgrade && apk --no-cache add ca-certificates tzdata bash supervisor make automake \
    gcc zip unzip unrar openrc sudo libc-dev openssl openssl-dev db-dev yaml gnupg linux-headers mlocate \
    dnssec-root perl perl-sys-hostname-long perl-net-dns perl-lwp-protocol-https perl-dev yaml perl-yaml \
    rsyslog curl perl-io-compress perl-dbd-mysql perl-dbd-odbc perl-xml-rss perl-encode perl-file-temp \
    perl-pod-coverage perl-test-deep perl-mail-spf g++ p7zip busybox-extras

# Install CPAN modules
RUN curl -L https://cpanmin.us | perl - App::cpanminus && cpan App::cpanoutdated && (cpan-outdated -p | cpanm || true) && \
    cpanm CPAN Log::Log4perl inc::latest Bundle::CPAN

# Install MariaDB
RUN apk add --update mariadb mariadb-server-utils mariadb-doc mariadb-openrc mariadb-client && \
    { \
    echo '#!/bin/bash'; \
    echo 'touch /tmp/init; [[ ! -f /etc/mysql/my.cnf ]] && (cp /usr/share/mariadb/my-small.cnf /etc/mysql/my.cnf && chown mysql:mysql /etc/mysql/my.cnf)'; \
    echo '[[ ! -d /run/mysqld ]] && (mkdir -p /run/mysqld && chown -R mysql:mysql /run/mysqld)'; \
    echo "[[ -n \"${SKIP_INNODB}\" ]] || [[ -f \"/var/lib/mysql/noinnodb\" ]] && sed -i -e '/\[mysqld\]/a skip-innodb\ndefault-storage-engine=MyISAM\ndefault-tmp-storage-engine=MyISAM' -e '/^innodb/d' /etc/mysql/my.cnf"; \
    echo "if [ -z \"\$(ls -A /var/lib/mysql/)\" ]; then ROOTPW=\"''\""; \
    echo "  [[ -n \"${SKIP_INNODB}\" ]] && touch /var/lib/mysql/noinnodb; [[ -n \"${MYSQL_ROOT_PASSWORD}\" ]] && ROOTPW=\"PASSWORD('${MYSQL_ROOT_PASSWORD}')\""; \
    echo "  echo \"INSERT INTO user VALUES ('%','root',${ROOTPW},'Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','','','','',0,0,0,0,'','','N', 'N','', 0);\" > /usr/share/mariadb/mysql_system_tables_data.sql"; \
    echo "  mysql_install_db --rpm  --user=mysql --cross-bootstrap; [[ -n \"${MYSQL_USER_DB}\" ]] && echo \"create database if not exists ${MYSQL_USER_DB} character set utf8 collate utf8_general_ci; \" >> /tmp/init"; \
    echo "  echo \"grant all on ${MYSQL_USER_DB}.* to '${MYSQL_USER}'@'%' identified by '${MYSQL_USER_PASSWORD}'; \" >> /tmp/init"; \
    echo '  echo "flush privileges;" >> /tmp/init'; \
    echo 'fi; /usr/bin/mysqld --skip-name-resolve --user=mysql --debug-gdb --init-file=/tmp/init'; \
    } | tee /maria-run.sh && chmod a+x /maria-run.sh

# Install ClamAV
RUN apk add --update clamav clamav-daemon && mkdir /run/clamav && chown clamav /run/clamav && \
    { \
    echo '#!/bin/bash'; \
    echo '[[ -d /var/log/clamav ]] || (mkdir /var/log/clamav && chown clamav /var/log/clamav)'; \
    echo '/usr/bin/freshclam -v'; \
    } | tee /freshclam-daily.sh && chmod a+x /freshclam-daily.sh && \
    { \
    echo '#!/bin/bash'; \
    echo '[[ -d /var/log/clamav ]] || mkdir /var/log/clamav'; \
    echo 'chown clamav /var/log/clamav'; \
    echo '/usr/sbin/clamd -c /etc/clamav/clamd.conf &'; \
    } | tee /clamd-run.sh && chmod a+x /clamd-run.sh && \
    /clamd-run.sh && freshclam -v && \
    (cpan File::Scan::ClamAV || true) && cd /root/.cpan/build/File-Scan-ClamAV-1.95-0 && make install && ln -s /freshclam-daily.sh /etc/periodic/daily/freshclam

# Install Postfix & Assign Port 1025
RUN apk add --update postfix && postconf -e smtputf8_enable=no; postalias /etc/postfix/aliases; postconf -e mydestination=; \
    postconf -e relay_domains=; postconf -e smtpd_delay_reject=yes; postconf -e smtpd_helo_required=yes; \
    postconf -e "smtpd_helo_restrictions=permit_mynetworks,reject_invalid_helo_hostname,permit"; \
    postconf -e "mynetworks=127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"; \
    sed -i -r -e 's/smtp      inet  n       -       n       -       -       smtpd/1025      inet  n       -       n       -       -       smtpd/' /etc/postfix/master.cf; \
    chown root /var/spool/postfix && chown root /var/spool/postfix/pid

# Install OpenDKIM
RUN apk add --update opendkim opendkim-utils && cp /etc/opendkim/opendkim.conf /etc/ && \
    { \
    echo '#!/bin/bash'; \
    echo '[[ -d /etc/opendkim/TrustedHosts ]] || mkdir /etc/opendkim/TrustedHosts'; \
    echo '[[ -d /etc/opendkim/KeyTable ]] || mkdir /etc/opendkim/KeyTable'; \
    echo '[[ -d /etc/opendkim/SigningTable ]] || mkdir /etc/opendkim/SigningTable'; \
    echo '[[ ! -f /etc/opendkim/opendkim.conf ]] && cp /etc/opendkim.conf /etc/opendkim/opendkim.conf'; \
    echo 'chown opendkim /etc/opendkim -R'; \
    echo 'sudo -u opendkim /usr/sbin/opendkim -p inet:8891 -x /etc/opendkim/opendkim.conf'; \
  } | tee /opendkim-run.sh && chmod a+x /opendkim-run.sh && \
  mkdir /run/opendkim && chown opendkim /run/opendkim && \
  echo 'Canonicalization        relaxed/simple' >> /etc/opendkim.conf && \
  echo 'ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts' >> /etc/opendkim.conf && \
  echo 'InternalHosts           refile:/etc/opendkim/TrustedHosts' >> /etc/opendkim.conf && \
  echo 'KeyTable                refile:/etc/opendkim/KeyTable' >> /etc/opendkim.conf && \
  echo 'SigningTable            refile:/etc/opendkim/SigningTable' >> /etc/opendkim.conf

# Get & Install ASSP, filecommander, and libs
RUN cd /usr/share && wget --no-check-certificate https://sourceforge.net/projects/assp/files/latest/download?source=files -O ASSP.zip && unzip ASSP.zip && \
    mv assp/assp.cfg.rename_on_new_install assp/assp.cfg && cd /usr/share/assp && touch /usr/share/assp/assp.cfg.setdefaults && \
    addgroup assp && adduser -D assp -G assp assp && \
    wget https://sourceforge.net/projects/assp/files/ASSP%20V2%20multithreading/ASSP%20V2%20module%20installation/assp.mod.zip/download -O assp.mod.zip && \
    unzip assp.mod.zip && cd assp.mod/install && sed -i 's|/OpenSSL|/LibreSSL|g' mod_inst.pl && \
    cd /usr/share/assp && \
    wget --no-check-certificate https://sourceforge.net/projects/assp/files/ASSP%20V2%20multithreading/filecommander/1.05.ZIP/download -O filecommander-1.05.zip && \
    unzip filecommander-1.05.zip && yes | mv 1.05/images/* /usr/share/assp/images && yes | mv 1.05/lib/* /usr/share/assp/lib && \
    cd /usr/share/assp && \
    wget --no-check-certificate https://sourceforge.net/projects/assp/files/ASSP%20V2%20multithreading/lib/lib.zip/download -O assp-lib.zip && \
    (yes | unzip assp-lib.zip) && chown assp:assp /usr/share/assp -R && chmod +x /usr/share/assp/assp.pl && \
    echo '#!/bin/bash' > /assp-run.sh && \
    echo 'if [ -z $(ls -A /usr/share/assp) ]; then' >> /assp-run.sh && \
    echo '  cp -rp /usr/share/assp-orig/* /usr/share/assp' >> /assp-run.sh && \
    echo 'fi' >> /assp-run.sh && \
    echo 'cd /usr/share/assp && chown assp:assp /usr/share/assp -R && /usr/share/assp/assp.pl' >> /assp-run.sh && \
    chmod a+x /assp-run.sh
RUN cpanm -n Mail::SPF::Query Encode::Detect Schedule::Cron Sys::CpuAffinity
RUN { \
    echo "your@address.here.com"; \
    echo "youraddress@here.com"; \
    } | tee /usr/share/assp/files/localuser.txt && \
    chown assp:assp /usr/share/assp/files/localuser.txt && chmod 755 /usr/share/assp/files/localuser.txt
RUN cd /usr/share/assp/assp.mod/install && perl mod_inst.pl && (cpan-outdated -p | cpanm || true)
RUN mv /usr/share/assp /usr/share/assp-orig && mkdir /usr/share/assp && chown assp:assp /usr/share/assp
RUN { \
    echo '#!/bin/bash'; \
    echo 'if [ ! -f /usr/share/assp/assp.cfg.setdefaults ]; then exit 0; fi'; \
    echo 'sleep 60;'; \
    echo 'rm -rf /usr/share/assp/assp.cfg.setdefaults'; \
    echo "sed -i 's|runAsUser:=|runAsUser:=assp|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|runAsGroup:=|runAsGroup:=assp|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|myhost:=|myhost:=127.0.0.1|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|mydb:=|mydb:=assp|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|myuser:=|myuser:=assp|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|mypassword:=|mypassword:=${ASSP_PASS}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|whitelistdb:=database/whitelist|whitelistdb:=DB:|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|delaydb:=database/delaydb|delaydb:=DB:|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|redlist:=database/redlist|redlist:=DB:|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|spamdb:=database/spamdb|spamdb:=DB:|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|ldaplistdb:=database/ldaplist|ldaplistdb:=DB:|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|adminusersdb:=|adminusersdb:=DB:|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|persblackdb:=database/persblack|persblackdb:=DB:|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|pbdb:=database/pb/pbdb|pbdb:=DB:|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|smtpDestination:=125|smtpDestination:=${SMTP_DESTINATION}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|listenPortSSL:=|listenPortSSL:=465|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|smtpDestinationSSL:=|smtpDestinationSSL:=${SMTP_DESTINATION_SSL}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's/acceptAllMail:=/acceptAllMail:=${ACCEPT_ALL_MAIL}/g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|DoLocalSenderDomain:=|DoLocalSenderDomain:=1|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|DoLocalSenderAddress:=|DoLocalSenderAddress:=1|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|relayHost:=|relayHost:=${RELAY_HOST}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|relayPort:=|relayPort:=${RELAY_PORT}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's/allowRelayCon:=/allowRelayCon:=${ALLOW_RELAY_CON}/g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|defaultLocalHost:=assp.local|defaultLocalHost:=${DEFAULT_LOCALHOST}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|sendHamInbound:=|sendHamInbound:=${SEND_HAM_INBOUND}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|sendHamOutbound:=|sendHamOutbound:=${SEND_HAM_OUTBOUND}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|sendAllPostmaster:=|sendAllPostmaster:=${POSTMASTER}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|LocalAddresses_Flat:=|LocalAddresses_Flat:=file:files/localuser.txt|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's/localDomains:=putYourDomains.com|here.org/localDomains:=${LOCAL_DOMAINS}/g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's/myServerRe:=/myServerRe:=${MY_SERVER_RE}/g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's/noDelayAddresses:=/noDelayAddresses:=${NO_DELAY}/g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailAdminReportsTo:=|EmailAdminReportsTo:=${MAILADMIN}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailAdmins:=|EmailAdmins:=${MAILADMIN}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailHelp:=assphelp|EmailHelp:=assp-help|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailSpam:=asspspam|EmailSpam:=assp-spam|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailHam:=asspnotspam|EmailHam:=assp-notspam|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailWhitelistAdd:=asspwhite|EmailWhitelistAdd:=assp-white|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailWhitelistRemove:=asspnotwhite|EmailWhitelistRemove:=assp-notwhite|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailRedlistAdd:=asspred|EmailRedlistAdd:=assp-red|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailRedlistRemove:=asspnotred|EmailRedlistRemove:=assp-notred|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailSpamLoverAdd:=asspspamlover|EmailSpamLoverAdd:=assp-spamlover|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailSpamLoverRemove:=asspnotspamlover|EmailSpamLoverRemove:=assp-notspamlover|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailNoProcessingAdd:=asspnpadd|EmailNoProcessingAdd:=assp-npadd|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailNoProcessingRemove:=asspnprem|EmailNoProcessingRemove:=assp-nprem|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailAnalyze:=asspanalyze|EmailAnalyze:=assp-analyze|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|EmailFrom:=spammaster@yourdomain.com|EmailFrom:=spammaster@assp.local|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|sysLog:=|sysLog:=1|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|myName:=ASSP.nospam|myName:=${MY_NAME}|g' /usr/share/assp/assp.cfg;"; \
    echo "sed -i 's|enableGraphStats:=0|enableGraphStats:=1|g' /usr/share/assp/assp.cfg;"; \
    echo "kill -9 \`ps awwux | grep perl | grep assp | grep -v defaults | awk '{print \$1}'\`"; \
} | tee /assp-setdefaults.sh && chmod a+x /assp-setdefaults.sh

# Configure supervisord
RUN { \
    echo '[supervisord]'; \
    echo 'nodaemon        = true'; \
    echo 'user            = root'; \
    echo 'logfile         = /var/log/supervisord'; echo; \
    echo '[program:rsyslog]'; \
    echo 'process_name    = rsyslog'; \
    echo 'autostart       = true'; \
    echo 'autorestart     = unexpected'; \
    echo 'directory       = /etc'; \
    echo 'command         = /usr/sbin/rsyslogd -n'; \
    echo 'startsecs       = 1'; \
    echo 'priority        = 1'; echo; \
    echo '[program:mariadb]'; \
    echo 'process_name    = mariadb'; \
    echo 'autostart       = true'; \
    echo 'autorestart     = unexpected'; \
    echo 'directory       = /usr'; \
    echo 'command         = /maria-run.sh'; \
    echo 'startsecs       = 5'; echo; \
    echo '[program:clamd]'; \
    echo 'process_name    = clamd'; \
    echo 'autostart       = true'; \
    echo 'autorestart     = unexpected'; \
    echo 'directory       = /usr'; \
    echo 'command         = /clamd-run.sh'; \
    echo 'startsecs       = 20'; echo; \
    echo '[program:crond]'; \
    echo 'process_name    = crond'; \
    echo 'autostart       = true'; \
    echo 'autorestart     = unexpected'; \
    echo 'directory       = /usr'; \
    echo 'command         = /usr/sbin/crond -f'; \
    echo 'startsecs       = 5'; echo; \
    echo '[program:postfix]'; \
    echo 'process_name    = postfix'; \
    echo 'autostart       = true'; \
    echo 'autorestart     = unexpected'; \
    echo 'directory       = /etc/postfix'; \
    echo 'command         = /usr/sbin/postfix -c /etc/postfix start'; \
    echo 'startsecs       = 20'; echo; \
    echo '[program:opendkim]'; \
    echo 'process_name    = opendkim'; \
    echo 'autostart       = true'; \
    echo 'autorestart     = false'; \
    echo 'directory       = /etc/opendkim'; \
    echo 'command         = /opendkim-run.sh'; \
    echo 'startsecs       = 5'; echo; \
    echo '[program:assp]'; \
    echo 'process_name    = assp'; \
    echo 'autostart       = true'; \
    echo 'autorestart     = unexpected'; \
    echo 'directory       = /'; \
    echo 'command         = /assp-run.sh'; \
    echo 'startsecs       = 30'; \
    echo '[program:assp-setdefaults]'; \
    echo 'process_name    = assp-setdefaults'; \
    echo 'autostart       = true'; \
    echo 'autorestart     = false'; \
    echo 'directory       = /'; \
    echo 'command         = /assp-setdefaults.sh'; \
    echo 'startsecs       = 90'; \
    } | tee /etc/supervisord.conf

# Cleanup any cached files
RUN (rm -rf /root/.cpan/* 2>/dev/null || true) && (rm "/tmp/"* 2>/dev/null || true) && (rm -rf /var/cache/apk/* 2>/dev/null || true)

# Instantiate Volumes
VOLUME ["/etc/mysql","/var/lib/mysql","/var/log","/var/spool/postfix","/etc/opendkim","/usr/share/assp"]

# Running final script
ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
