% Copyright (C) 2018  Conrad Steenberg <conrad.steenberg@gmail.com>

% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.

%%%---------------------------------------------------------------------------
%% @doc protodb public API
%% @end
%%%---------------------------------------------------------------------------

-module(protodb).
-export([
          config/2, connect/2,
          create_migration/3,
          disconnect/2,
          execute/4,
          initdb/2,
          list_migrations/1,
          list_migrations/2,
          load_immutable/3,
          load_immutable/4,
          migrate_down/1,
          migrate_down/2,
          migrate_down/3,
          migrate/1,
          migrate/2,
          migrate/3,
          reset/2,
          prepare_statement/4
        ]).

%%============================================================================
%% API
%%============================================================================
%%- Hardcoded database configs -----------------------------------------------
config(erlcass, Poolname) ->
  Config = [{erlcass, ["host", 9042, Poolname, "username", "password"]}],
  {ok, MigDir} = application:get_env(protodb, migrations),
  {erlcass, Config, MigDir};

config(pgsql, Database) ->
  {ok, ClientConfig} = application:get_env(protodb, pgsql_config),
  Config = [{pgsql, lists:append(ClientConfig, [{database, Database}])}],
  {ok, MigDir} = application:get_env(protodb, migrations),
  {pgsql, Config, MigDir}.

%%- Connect helpers ----------------------------------------------------------
connect(erlcass, Poolname) ->
  Config = ["host", 9042, Poolname, "username", "password"],
  Conn = erlsqlmigrate_core:connect(erlcass, Config),
  lager:debug("DB Connect: ~p", [Conn]),
  initdb_models(Conn, Poolname);

connect(pgsql, Database) ->
  {ok, ClientConfig} = application:get_env(protodb, pgsql_config),
  Config = lists:append(ClientConfig, [{database, Database}]),
  try erlsqlmigrate_core:connect(pgsql, Config) of
    {pgsql_connection, _Pid} = Conn ->
      lager:debug("DB Connect: ~p", [Conn]),
      initdb_models(Conn, Database)
  catch
    {pgsql_error, Err} ->
      lager:error("DB Connecction Error:~n~p", [Err]),
      {error, Err}
  end.

%%- Disvonnect helpers -------------------------------------------------------
disconnect(_, {ConnType, Pid}) ->
  erlsqlmigrate_core:disconnect({ConnType, Pid}).

%%- Do all migrations --------------------------------------------------------
migrate({_, _Config, _MigDir}=DbConf) ->
  migrate(DbConf, []).
migrate({_, Config, MigDir}, Names) ->
  erlsqlmigrate:create(Config, MigDir, []),
  erlsqlmigrate:up(Config, MigDir, Names);
migrate(DbType, Poolname) ->
  migrate(config(DbType, Poolname), []).
migrate(DbType, Poolname, Name) ->
  migrate(config(DbType, Poolname), [Name]).

%%- Roll back one migration --------------------------------------------------
migrate_down({_, _Config, _MigDir}=DbConf) ->
  migrate_down(DbConf, []).
migrate_down({_, Config, MigDir}, Names) ->
  erlsqlmigrate:create(Config, MigDir, []),
  erlsqlmigrate:down(Config, MigDir, Names);
migrate_down(DbType, Poolname) ->
  migrate_down(config(DbType, Poolname), []).
migrate_down(DbType, Poolname, Name) ->
  migrate_down(config(DbType, Poolname), [Name]).

%%- List migrations ---------------------------------------------------------
list_migrations({_, Config, MigDir}) ->
  erlsqlmigrate:list(Config, MigDir, []).
list_migrations(DbType, Poolname) ->
  list_migrations(config(DbType, Poolname)).

%%- Create migration ---------------------------------------------------------
create_migration({_, Config, MigDir}, Name) ->
  erlsqlmigrate:create(Config, MigDir, Name).
create_migration(DbType, Poolname, Name) ->
  create_migration(config(DbType, Poolname), Name).

%%- Initialize the databases -------------------------------------------------
initdb(DbType, Poolname) ->
  case ets:info(protodb_sessions) of
    undefined ->
      ets:new(protodb_sessions, [bag, named_table, public]);
    _ -> ok
  end,

  try config(DbType, Poolname) of
    DbConfig ->
      migrate(DbConfig),
      connect(DbType, Poolname)
  catch
    <<"Session is not connected">> ->
      {error, not_connected}
  end.

initdb_models(Conn, Poolname) ->
 case ets:match(protodb_sessions, Conn) of
    [] ->
      {ok, Modules} =  application:get_env(protodb, models),
      [Module:initdb(Conn, Poolname) || Module <- Modules],
      ets:insert(protodb_sessions, Conn),
      Conn;
    _ ->
      Conn
  end.

%- Reset Database ------------------------------------------------------------
reset(DbType, Poolname) when is_atom(DbType) ->
  try config(DbType, Poolname) of
    DbConfig ->
      migrate_down(DbConfig, []),
      migrate(DbConfig),
      connect(DbType, Poolname)
  catch
    <<"Session is not connected">> ->
      {error, not_connected}
  end.

%------------------------ Load data with caching ------------------------------
load_immutable(Module, Conn, Arg) ->
  case e2qc:cache(Module, {Conn, Arg}, 30, fun() ->
      Module:load_worker(Conn, Arg)
    end) of
  {ok, _} = Result ->
    Result;
  {error, _} = Error ->
    e2qc:evict(Module, {pgsql_connection, Arg}),
    Error
  end.
load_immutable(Module, Conn, Arg1, Arg2) ->
  case e2qc:cache(Module, {Conn, {Arg1, Arg2}}, 30, fun() ->
      Module:load_worker(Conn, Arg1, Arg2)
    end) of
  {ok, _} = Result ->
    Result;
  {error, _} = Error ->
    e2qc:evict(Module, {pgsql_connection, {Arg1, Arg2}}),
    Error
  end.

%------------------------ Prepared statement helpers --------------------------
prepare_statement({erlcass_connection, _KeySpace}, Name, Statement, Args) ->
  case
    erlcass:add_prepare_statement(Name, binary:list_to_bin(io_lib:format(Statement, Args))) of
  ok ->
    {ok};
  {error, already_exist} ->
    {ok};
  Error ->
    lager:error("Error creating prepared statement ~s:~n~p~n", [Name, Error]),
    {error, Error}
  end;

prepare_statement({pgsql_connection, _Pid} = Conn, Name, Statement, Args) ->
  case
    pgsql_connection:simple_query(binary:list_to_bin(io_lib:format(Statement, Args)), Conn) of
  {prepare,[]} ->
    {ok};
  {error, already_exist} ->
    {ok};
  Error ->
    lager:error("Error creating prepared statement ~s:~n~p~n", [Name, Error]),
    {error, Error}
  end.

%------------------------ Execute prepared statement -------------------------
execute({ecass_connection, _Pid} = Conn, _Name, Statement, Args) ->
  erlcass:extended_query(Statement, Args , Conn);
execute({pgsql_connection, _Pid} = Conn, _Name, Statement, Args) ->
  lager:debug(Statement),
  lager:debug("~p", [Args]),
  pgsql_connection:extended_query(Statement, Args, Conn).

%% ================================== Tests ==================================
