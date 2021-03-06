classdef Daemon < handle
    properties(Access=private)
        exposed
        sock
        last_alert
    end
    properties(SetAccess=private)
        bind_address
    end
    properties
        smtp_server
        smtp_username
        smtp_password
        alert_email
        alert_on_exceptions = true
        minimum_time_between_alerts = 10*60 % Default is 10 minutes.
        daemon_email
        daemon_name = 'daemon'
        debug_enabled = false
        email_system_initialized = false
    end
    methods
        function obj = Daemon(address)
            obj.exposed = containers.Map();
            obj.bind_address = address;
            obj.sock = zmq.socket('rep');
            obj.sock.bind(address);
            obj.expose_func(@()obj.exposed.keys(), 'rpc.list');
            obj.expose_func(@()[], 'rpc.heartbeat');
        end

        function serve_once(obj, varargin)
            p = inputParser();
            p.addOptional('timeout', Inf);
            p.parse(varargin{:});
            timeout = p.Results.timeout;
            if ~zmq.wait(obj.sock, timeout)
                return;
            end
            msg = obj.sock.recv();
            if obj.debug_enabled
                disp(['req ' msg]);
            end
            rep = struct();
            try
                parsed = json.load(msg);
                if iscell(parsed.params)
                    params = parsed.params;
                else
                    params = num2cell(parsed.params);
                end
                rep.result = obj.call(parsed.method, params);
            catch err
                rep.error = err.message;
                if obj.alert_on_exceptions
                    obj.send_alert_from_exception('Exception occured', err);
                end
                disp(getReport(err));
            end
            rmsg = json.dump(rep);
            if obj.debug_enabled
                disp(['rep ' rmsg]);
            end
            obj.sock.send(rmsg);
        end

        function serve_period(obj, period)
            serve_start = tic();
            keep_going = true;
            while keep_going
                time_left = max(0, period - toc(serve_start));
                obj.serve_once(time_left*1000);
                if toc(serve_start) > period
                    keep_going = false;
                end
            end
        end

        function serve_forever(obj)
            while true
                obj.serve_once();
            end
        end

        function expose(obj, target, method_name, varargin)
            p = inputParser();
            p.addOptional('name', method_name);
            p.parse(varargin{:});
            name = p.Results.name;
            obj.expose_func(@(varargin) target.(method_name)(varargin{:}), name);
        end

        function expose_func(obj, func, name)
            if obj.exposed.isKey(name)
                error('A function named %s has already been exposed.', name);
            end
            obj.exposed(name) = func;
        end

        function initialize_email_system(obj)
            if obj.email_system_initialized
                return;
            end

            if ~isempty(obj.smtp_server)
                smtp = obj.smtp_server;
            else
                smtp = 'mail';
            end

            if ~isempty(obj.daemon_email)
                from = obj.daemon_email;
            else
                from = sprintf('%s@%s', obj.daemon_name, getHostname());
            end

            if ~isempty(obj.alert_email)
                setpref('Internet','SMTP_Server', smtp);
                setpref('Internet','E_mail', from);
                if ~isempty(obj.smtp_username)
                    props = java.lang.System.getProperties;
                    props.setProperty('mail.smtp.auth', 'true');
                    setpref('Internet','SMTP_Username', obj.smtp_username);
                    setpref('Internet','SMTP_Password', obj.smtp_password);
                end
            end
            obj.email_system_initialized = true;
        end

        function send_alert(obj, subject, body)
            if isempty(obj.alert_email)
                return
            end
            obj.initialize_email_system();
            if isempty(obj.last_alert) || toc(obj.last_alert) > obj.minimum_time_between_alerts
                try
                    sendmail(obj.alert_email, subject, ...
                        sprintf('Sent from "%s":\n%s', getHostname(), body));
                catch err
                    warning(['Could not send email: ' err.message]);
                end

                obj.last_alert = tic();
            end
        end

        function send_alert_from_exception(obj, subject, err)
            obj.send_alert(subject, ...
                getReport(err, 'extended', 'hyperlinks', 'off'));
        end
    end
    methods(Access=private)
        function result = call(obj, method, params)
            if ~obj.exposed.isKey(method)
                error('No such method: %s', msg_parsed.method);
            end
            func = obj.exposed(method);
            result = func(params{:});
        end
    end
end

function hostname = getHostname()
    [~, hostname] = system('hostname');
    hostname = strtrim(hostname);
end
