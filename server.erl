%% Authors: Christian Törnqvist and Zijian Qi

%% - Server module
%% - The server module creates a parallel registered process by spawning a process which 
%% evaluates initialize(). 
%% The function initialize() does the following: 
%%      1/ It makes the current process as a system process in order to trap exit.
%%      2/ It creates a process evaluating the store_loop() function.
%%      4/ It executes the server_loop() function.

-module(server).

-export([start/0]).

%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start() -> 
    register(transaction_server, spawn(fun() ->
					       process_flag(trap_exit, true),
					       Val= (catch initialize()),
					       io:format("Server terminated with:~p~n",[Val])
				       end)).

initialize() ->
    process_flag(trap_exit, true),
    Initialvals = [{a,0},{b,0},{c,0},{d,0}], %% All variables are set to 0
    Locks = [{a, unlocked, [], 0},{b, unlocked, [], 0},{c, unlocked, [], 0},{d, unlocked, [], 0}], %% unlocked = the lock state of the variable. It can also be write_lock and read_lock. The list contains the owner(s) of the lock and if a user wants to write an amount to a variable, that value will be where the '0' is.
    ServerPid = self(),
    StorePid = spawn_link(fun() -> store_loop(ServerPid,Initialvals) end),
    server_loop([],StorePid,Locks).
    
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
%% the values of the global variable a, b, c and d 


server_loop(ClientList,StorePid, Locks) ->
    io:format("in server_loop~n"),
    receive
	{login, MM, Client} -> 
	    MM ! {ok, self()},
	    io:format("New client has joined the server:~p.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(add_client(Client,ClientList),StorePid, Locks);
	{close, Client} -> 
	    io:format("Client~p has left the server.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(remove_client(Client,ClientList),StorePid, Locks);
	{request, Client} -> 
	    Client ! {proceed, self()},
	    server_loop(ClientList,StorePid, Locks);
	{confirm, Client, Transaction_length} -> 
	    io:format("Attempted commit from client~n"),
	    {_, Actions_received} = lists:keyfind(Client, 1, ClientList),
	    case Actions_received == Transaction_length of
		false ->
		    io:format("Package loss occurred~n"),
		    Abort_reason = {abort, self(), package_loss, Actions_received, Transaction_length},
		    abort_and_continue_server_loop(ClientList, StorePid, Locks, Client, Abort_reason);
		true ->
		    Client ! {committed, self()},
		    New_client_list = lists:keyreplace(Client, 1, ClientList, {Client, 0}),
		    update_amounts(Locks, Client, self(), StorePid),
		    io:format("Locks before: ~p~n", [Locks]),
		    New_locks = release_locks(Locks, Client),
		    io:format("Locks after: ~p~n", [New_locks]),
		    StorePid ! {print, self()},
		    server_loop(New_client_list,StorePid, New_locks)
	    end;
		{action, Client, Act} ->
		    io:format("Received~p from client~p.~n", [Act, Client]),
		    
		    {_, Actions_count} = lists:keyfind(Client, 1, ClientList),
		    New_client_list = lists:keyreplace(Client, 1, ClientList, {Client, Actions_count + 1}),
		    case Act of
			{_, Variable} ->
			    try_lock(Variable, Locks, Client, 0, New_client_list, StorePid, read);
			{_, Variable, Amount} ->
			    try_lock(Variable, Locks, Client, Amount, New_client_list, StorePid, write)
		    end;
	debug ->
	    StorePid ! {print, self()}
	    
    after 50000 ->
	case all_gone(ClientList) of
	    true -> exit(normal);    
	    false -> server_loop(ClientList,StorePid, Locks)
	end
    end.

%% - The values are maintained here
store_loop(ServerPid, Database) -> 
    receive
	{print, ServerPid} -> 
	    io:format("Database status:~n~p.~n",[Database]),
	    store_loop(ServerPid,Database);
	{update, ServerPid, Variable, Amount} ->
	    % Do we increment or replace the amount when doing write?
	    New_database = lists:keyreplace(Variable, 1, Database, {Variable, Amount}),
	    store_loop(ServerPid,New_database)
    end.
%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

			

%%%%%%%%%%%%%%%%%%%%%%% HELP FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

try_lock(Variable, Locks, Client, Amount, ClientList, StorePid, Action) ->
    case Action of
	write ->  Result = acquire_write_lock(Variable, Locks, Client, Amount);
	read ->   Result = acquire_read_lock(Variable, Locks, Client)
    end,
    case Result of
	failed -> 
	    Abort_reason = {abort, self(), lock_acquire_failed, Variable},
	    abort_and_continue_server_loop(ClientList, StorePid, Locks, Client, Abort_reason);
	New_locks ->
	    server_loop(ClientList,StorePid, New_locks)
    end.

acquire_read_lock(Variable, Locks, Client) ->
    case lists:keyfind(Variable, 1, Locks) of
	{_Variable, unlocked, _Lock_owners, Amount} ->
	    New_locks = lists:keyreplace(Variable, 1, Locks, {Variable, read_lock, [Client], Amount}),
	    New_locks;
	{_, read_lock, Lock_owners, Amount} ->
	    case lists:keyfind(Client, 1, Lock_owners) of %% To not have multiple entries of Client in the list Lock_owners.
		false -> 
		    New_locks = lists:keyreplace(Variable, 1, Locks, {Variable, read_lock, [Client|Lock_owners], Amount}),
		    New_locks;
		true ->
		    Locks %&client_already_owns_the_lock.
	    end;
	{_, write_lock, [Singular_lock_owner], _} -> %% Client is the only owner of the write lock so he is allowed to read.
	    case Singular_lock_owner == Client of
		true ->
		    Locks;
		false ->
		    failed
	    end;
	{_, write_lock, _, _} ->
	    failed
    end.

acquire_write_lock(Variable, Locks, Client, Amount) ->
    case lists:keyfind(Variable, 1, Locks) of
  	{_, unlocked, _, _} ->
  	    New_lists = lists:keyreplace(Variable, 1, Locks, {Variable, write_lock, [Client], Amount}),
  	    New_lists;
		
  	{_, read_lock, [Singular_lock_owner], _} -> %% Client is the only owner of the read lock so he is allowed the write lock
  	    case Singular_lock_owner == Client of
  		true ->
  		    New_lists = lists:keyreplace(Variable, 1, Locks, {Variable, write_lock, [Client], Amount}),
  		    New_lists;
  		false ->
  		    failed
  	    end;
	{_, read_lock, _, _} ->	
	    failed;
	{_, write_lock, [Singular_lock_owner], _} -> %% Client is the only owner of the write lock so he is allowed to read.
  	    io:format("write over another write in the current transaction~n"),
  	    case Client == Singular_lock_owner of
  		true ->
  		    New_locks = lists:keyreplace(Variable, 1, Locks, {Variable, write_lock, [Singular_lock_owner], Amount}),
  		    New_locks;
  		false ->
  		    failed
  	    end;
  	{_, write_lock, _, _} ->
  	    io:format("write lock acquire failed~n"),
	    failed
    end.

abort_and_continue_server_loop(ClientList, StorePid, Locks, Client, Abort_reason) ->
    Client ! Abort_reason,
    io:format("ClientList ~p, StorePid ~p, Locks ~p, Client ~p~n", [ClientList, StorePid, Locks, Client]),
    New_client_list = lists:keyreplace(Client, 1, ClientList, {Client, 0}),    
    io:format("Locks before: ~p~n", [Locks]),
    New_locks = release_locks(Locks, Client),
    io:format("Locks after: ~p~n", [New_locks]),
    server_loop(New_client_list,StorePid, New_locks).


release_locks(Locks, Client) -> release_locks_aux([a,b,c,d], Locks, Client).
release_locks_aux([], Locks, _Client) ->
    Locks;
release_locks_aux([H|T], Locks, Client) ->
    case lists:keyfind(H, 1, Locks) of
	{_, unlocked, _, _} ->
	    release_locks_aux(T, Locks, Client);
	{Variable, read_lock, Client_list, _} ->
	    New_client_list = lists:delete(Client, Client_list),
%	    New_client_list = keydelete(Client_list, [], Client),
	    case empty(New_client_list) of
		true -> 
		    New_locks = lists:keyreplace(Variable, 1, Locks, {Variable, unlocked, [], 0}),
		    release_locks_aux(T, New_locks, Client);
		false ->
		    New_locks = lists:keyreplace(Variable, 1, Locks, {Variable, read_lock, New_client_list, 0}),
		    release_locks_aux(T, New_locks, Client)
		end;
	{Variable, write_lock, [Lock_owner], _} ->
	    case Client == Lock_owner of
		true ->
		    New_locks = lists:keyreplace(Variable, 1, Locks, {Variable, unlocked, [], 0}),
		    release_locks_aux(T, New_locks, Client);
		false ->
		    release_locks_aux(T, Locks, Client)
	    end;
	E ->
	    io:format("~nError: ~p~n", [E])
    end.

empty([]) -> true;
empty(_) -> false.

update_amounts([], _, _, _) -> ok;
update_amounts([Head_locks|Tail_locks], Client, ServerPid, StorePid) ->
    case Head_locks of
	{Variable, write_lock, [Lock_owner], Amount} ->
	    case Client == Lock_owner of
		true ->
		    StorePid ! {update, ServerPid, Variable, Amount},
		    update_amounts(Tail_locks, Client, ServerPid, StorePid);
		false ->
		    update_amounts(Tail_locks, Client, ServerPid, StorePid)
	    end;
	_Other ->
	    update_amounts(Tail_locks, Client, ServerPid, StorePid)
    end.
%%%%%%%%%%%%%%%%%%%%%%% HELP FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% - Low level function to handle lists
add_client(C,T) -> [{C,0}|T].

remove_client(_,[]) -> [];
remove_client(C, [C|T]) -> T;
remove_client(C, [H|T]) -> [H|remove_client(C,T)].

all_gone([]) -> true;
all_gone(_) -> false.
