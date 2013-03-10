erl -sname packet_mon -cookie packet_mon -pa ebin -pa deps/*/ebin -boot start_sasl -s lager -s packet_mon -config ./start.config -args_file start.args
