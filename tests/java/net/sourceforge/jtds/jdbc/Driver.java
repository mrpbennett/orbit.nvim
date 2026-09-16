package net.sourceforge.jtds.jdbc;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.DriverPropertyInfo;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.logging.Logger;

/** Deterministic JDBC seam for exercising the Orbit helper without a server. */
public final class Driver implements java.sql.Driver {
    static {
        try {
            DriverManager.registerDriver(new Driver());
        } catch (SQLException error) {
            throw new ExceptionInInitializerError(error);
        }
    }

    @Override
    public Connection connect(String url, Properties properties) throws SQLException {
        if (!acceptsURL(url)) return null;
        validateProperties(url, properties);
        return proxy(Connection.class, new ConnectionHandler());
    }

    private static void validateProperties(String url, Properties properties) throws SQLException {
        require("orbit".equals(properties.getProperty("user")), "missing user");
        require("secret".equals(properties.getProperty("password")), "missing password");
        if (url.contains("sql.test")) {
            require("authenticate".equals(properties.getProperty("ssl")), "SQL TLS mode mismatch");
            require(properties.getProperty("domain") == null, "SQL auth included a domain");
            require(properties.getProperty("useNTLMv2") == null, "SQL auth enabled NTLMv2");
            return;
        }
        require("EXAMPLE".equals(properties.getProperty("domain")), "missing domain");
        require("true".equals(properties.getProperty("useNTLMv2")), "NTLMv2 not enabled");
        require("testdb".equals(properties.getProperty("databaseName")), "missing database");
        String expectedSsl = url.contains("trust.test") ? "require" : "authenticate";
        require(expectedSsl.equals(properties.getProperty("ssl")), "TLS mode mismatch");
    }

    private static void require(boolean condition, String message) throws SQLException {
        if (!condition) throw new SQLException(message, "08001");
    }

    @Override public boolean acceptsURL(String url) { return url.startsWith("jdbc:jtds:sqlserver://"); }
    @Override public DriverPropertyInfo[] getPropertyInfo(String url, Properties info) { return new DriverPropertyInfo[0]; }
    @Override public int getMajorVersion() { return 1; }
    @Override public int getMinorVersion() { return 3; }
    @Override public boolean jdbcCompliant() { return false; }
    @Override public Logger getParentLogger() { return Logger.getGlobal(); }

    private static final class ConnectionHandler implements InvocationHandler {
        private boolean closed;

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws SQLException {
            switch (method.getName()) {
                case "createStatement": return proxy(Statement.class, new StatementHandler());
                case "close": closed = true; return null;
                case "isClosed": return closed;
                case "isWrapperFor": return false;
                case "unwrap": throw new SQLException("not a wrapper");
                default: return defaultValue(method.getReturnType());
            }
        }
    }

    private static final class StatementHandler implements InvocationHandler {
        private List<ResultSet> results = new ArrayList<>();
        private int resultIndex;
        private int updateCount = -1;

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws SQLException {
            switch (method.getName()) {
                case "execute": return execute((String) args[0]);
                case "getResultSet": return results.isEmpty() ? null : results.get(resultIndex);
                case "getUpdateCount": return results.isEmpty() ? updateCount : -1;
                case "getMoreResults":
                    if (results.isEmpty()) {
                        updateCount = -1;
                        return false;
                    }
                    resultIndex++;
                    return resultIndex < results.size();
                case "close": return null;
                case "isWrapperFor": return false;
                case "unwrap": throw new SQLException("not a wrapper");
                default: return defaultValue(method.getReturnType());
            }
        }

        private boolean execute(String sql) throws SQLException {
            results = new ArrayList<>();
            resultIndex = 0;
            updateCount = -1;
            if (sql.equals("ERROR")) throw new SQLException("syntax error", "42000");
            if (sql.equals("CONNECTION_ERROR")) throw new SQLException("connection lost", "08006");
            if (sql.equals("UPDATE")) {
                updateCount = 1;
                return false;
            }
            if (sql.equals("DUPLICATE")) {
                results.add(result(new String[] { "value", "value" }, new String[][] { { "1", "2" } }));
                return true;
            }
            if (sql.equals("EMPTY_LABEL")) {
                results.add(result(new String[] { "" }, new String[][] { { "1" } }));
                return true;
            }
            if (sql.equals("LARGE")) {
                results.add(result(new String[] { "value" }, new String[][] { { "x".repeat(100_000) } }));
                return true;
            }
            results.add(result(
                    new String[] { "value", "missing", "unicode" },
                    new String[][] { { "line\nvalue", null, "\u03bb" }, { "NULL", "", "plain" } }));
            if (sql.equals("MULTI")) {
                results.add(result(new String[] { "second" }, new String[][] { { "2" } }));
            }
            return true;
        }
    }

    private static ResultSet result(String[] columns, String[][] values) {
        return proxy(ResultSet.class, new ResultSetHandler(columns, values));
    }

    private static final class ResultSetHandler implements InvocationHandler {
        private final String[] columns;
        private final String[][] values;
        private int row = -1;
        private boolean wasNull;

        ResultSetHandler(String[] columns, String[][] values) {
            this.columns = columns;
            this.values = values;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws SQLException {
            switch (method.getName()) {
                case "getMetaData": return metadata(columns);
                case "next": row++; return row < values.length;
                case "getString":
                    String value = values[row][((Integer) args[0]) - 1];
                    wasNull = value == null;
                    return value;
                case "wasNull": return wasNull;
                case "close": return null;
                case "isWrapperFor": return false;
                case "unwrap": throw new SQLException("not a wrapper");
                default: return defaultValue(method.getReturnType());
            }
        }
    }

    private static ResultSetMetaData metadata(String[] columns) {
        return proxy(ResultSetMetaData.class, (proxy, method, args) -> {
            switch (method.getName()) {
                case "getColumnCount": return columns.length;
                case "getColumnLabel": return columns[((Integer) args[0]) - 1];
                case "isWrapperFor": return false;
                case "unwrap": throw new SQLException("not a wrapper");
                default: return defaultValue(method.getReturnType());
            }
        });
    }

    @SuppressWarnings("unchecked")
    private static <T> T proxy(Class<T> type, InvocationHandler handler) {
        return (T) Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[] { type }, handler);
    }

    private static Object defaultValue(Class<?> type) {
        if (!type.isPrimitive()) return null;
        if (type == boolean.class) return false;
        if (type == byte.class) return (byte) 0;
        if (type == short.class) return (short) 0;
        if (type == int.class) return 0;
        if (type == long.class) return 0L;
        if (type == float.class) return 0F;
        if (type == double.class) return 0D;
        if (type == char.class) return '\0';
        return null;
    }
}
