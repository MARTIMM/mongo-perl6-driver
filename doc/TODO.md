# Bugs, known limitations and todo

## Todo

* Blog [A Consistent CRUD API](https://www.mongodb.com/blog/post/consistent-crud-api-next-generation-mongodb-drivers?jmp=docs&_ga=1.72964115.1411139568.1420476116)

### Speed
* Speed can be influenced by specifying types on all variables, but on the other hand, it might slow it down because of type checking. Need to investigate that. Again, typing variables helps resolving mistakes too!
* Take native types for simple things such as counters
* Setting constraints like (un)definedness etc on parameters
* The compile step of perl6 takes some time before running. This obviously depends on the code base of the programs. One thing I have done is removing all exception classes from the modules and replace them by only one class defined in MongoDB/Log.pm.
* The perl6 behaviour is also changed. One thing is that it generates parsed code in directory .precomp. The first time after a change in code it takes more time at the parse stage. After the first run the parsing time is shorter.

### Testing mongo\* servers
* Testing $mod in queries seems to have problems in version 3.0.5
* Table to map mongo status codes to severity level. This will modify the default severity when an error code from the server is received. Look for  [error table here](https://github.com/mongodb/mongo/blob/master/docs/errors.md)
* Find a way to incorporate the servers error codes into the log messages when server returns a failure.
* I am now more satisfied with logging because of the use of parts the Log::Async module. A few additions might be to use macros to get info at the calling point before sending to the \*-message() subs. This will make the search through the stack unnecessary.

* Must check for max BSON document size
* There is an occasional 'double free' bug in perl6 which torpedes tests now and then. This is a perl6 problem.

* Other items to check; [MongoDB Limits and Thresholds](https://docs.mongodb.org/manual/reference/limits/)

* Handle read/write concerns.
* Readconcern structure does not have to be a BSON::Document. no encoding, it isn't a server object! unless it sent to a mongos server!
* some tests in calculating the topology and server states needs some refinement.
* Design is changed, redraw time diagrams and others

* [Issue #23](https://github.com/MARTIMM/mongo-perl6-driver/issues/23)
