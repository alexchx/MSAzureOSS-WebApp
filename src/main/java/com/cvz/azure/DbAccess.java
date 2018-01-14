package com.cvz.azure;

import java.sql.*;
import java.util.ArrayList;
import java.util.Properties;

public class DbAccess {
	public ArrayList<Product> getProducts() throws Exception {
		ArrayList<Product> products= new ArrayList<Product>();
		// Initialize connection variables. 
        String host = "webosswamysqlserver.mysql.database.azure.com";
        String database = "webosswamysqldb";
        String user = "adminLogin@webosswamysqlserver";
        String password = "Beat@Apple123";
        
        // check that the driver is installed
        try
        {
            Class.forName("com.mysql.cj.jdbc.Driver");
        }
        catch (ClassNotFoundException e)
        {
            throw new ClassNotFoundException("MySQL JDBC driver NOT detected in library path.", e);
        }

        System.out.println("MySQL JDBC driver detected in library path.");

        Connection connection = null;

        // Initialize connection object
        try
        {
            String url = String.format("jdbc:mysql://%s/%s", host, database);           
           
            // Set connection properties.
            Properties properties = new Properties();
            properties.setProperty("user", user);
            properties.setProperty("password", password);
            properties.setProperty("useSSL", "true");
            properties.setProperty("verifyServerCertificate", "true");
            properties.setProperty("requireSSL", "false");
            properties.setProperty("serverTimezone", "UTC");

            // get connection
            connection = DriverManager.getConnection(url, properties);          
        }
        catch (SQLException e)
        {
            throw new SQLException("Failed to create connection to database.", e);
        }
        if (connection != null) 
        { 
            System.out.println("Successfully created connection to database.");

            // Perform some SQL queries over the connection.
            try
            {
            	Statement stmt = connection.createStatement(); 
                System.out.println("Successfully created connection to database.");

                String sql = "select * from products";    
                ResultSet rs = stmt.executeQuery(sql);                  
                    while (rs.next()){                      
                     
                        Product p = new Product();
                        p.Id = rs.getInt(1);
                        p.Title = rs.getString(2);
                        p.Description = rs.getString(3);
                        p.Category = rs.getString(4);
                        
                        products.add(p);
                    }
                    
                    rs.close();
                    stmt.close();
                    connection.close();
            }
            catch (SQLException e)
            {
                throw new SQLException("Encountered an error when executing given sql statement.", e);
            }       
        }
        else {
            System.out.println("Failed to create connection to database.");
        }
        System.out.println("Execution finished.");
        
        return products;
	}
}
