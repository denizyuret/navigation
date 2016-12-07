include("util.jl")
using ArgParse

function results(fname)
	d = Dict()
	s = readstring(pipeline(`less $fname`, `grep Epoch`))
	lns = split(s, "\n")
	for line in lns
		if line == ""
			continue;
		end
		l = split(line)

		v = parse(Float64, split(l[8], ",")[1])
		if haskey(d, l[9])
			if v > d[l[9]]
				d[l[9]] = v
			end
		else
			d[l[9]] = v
		end
	end
	return mean(values(d)), d
end

function printlogs(logs)
	for (r,d,f) in logs
		println("File: $f , Results: $r")
		for k in keys(d); println("$k : $(d[k])"); end
		println("")
	end
end

function main()
	args = parse_commandline()

	files = readdir(args["folder"])
	logs = Any[]

	for f in files
		try
			r, d = results(string(args["folder"], "/", f))
			push!(logs, (r, d, f))

		catch e
			println(e)
			println("Error on $f")
		end
	end

	sort!(logs, rev=true)
	printlogs(logs)
	
end

function parse_commandline()
	s = ArgParseSettings()

	@add_arg_table s begin
		"--folder"
			help = "folder contains the log files"
			default = "logs"
	end
	return parse_args(s)
end		

main()