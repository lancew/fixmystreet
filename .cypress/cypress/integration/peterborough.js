describe('new report form', function() {

  beforeEach(function() {
    cy.server();
    cy.route('/report/new/ajax*').as('report-ajax');
    cy.visit('http://peterborough.localhost:3001/');
    cy.contains('Peterborough');
    cy.get('[name=pc]').type('PE1 1HF');
    cy.get('[name=pc]').parents('form').submit();
    cy.get('#map_box').click();
    cy.wait('@report-ajax');
  });

  it('is hidden when emergency option is yes', function() {
    cy.pickCategory('Fallen branch');
    cy.nextPageReporting();
    cy.get('#form_emergency').select('yes');
    cy.get('.js-post-category-messages:visible').should('contain', 'Please phone customer services to report this problem.');
    cy.get('.js-reporting-page--next:visible').should('be.disabled');
    cy.get('#form_emergency').select('no');
    cy.get('.js-post-category-messages:visible').should('not.contain', 'Please phone customer services to report this problem.');
    cy.get('.js-reporting-page--next:visible').should('not.be.disabled');
  });

  it('is hidden when private land option is yes', function() {
    cy.pickCategory('Fallen branch');
    cy.nextPageReporting();
    cy.get('#form_private_land').select('yes');
    cy.get('.js-post-category-messages:visible').should('contain', 'The council do not have powers to address issues on private land.');
    cy.get('.js-reporting-page--next:visible').should('be.disabled');
    cy.get('#form_private_land').select('no');
    cy.get('.js-post-category-messages:visible').should('not.contain', 'The council do not have powers to address issues on private land.');
    cy.get('.js-reporting-page--next:visible').should('not.be.disabled');
  });

  it('correctly changes the asset select message', function() {
    cy.pickCategory('Street lighting');
    cy.get('.category_meta_message').should('contain', 'You can pick a light from the map');
    cy.pickCategory('Trees');
    cy.get('.category_meta_message').should('contain', 'You can pick a tree from the map');
  });

  it('displays nearby roadworks', function() {
    cy.fixture('peterborough_roadworks.json');
    cy.route('/streetmanager.php**', 'fixture:peterborough_roadworks.json').as('roadworks');
    cy.wait('@roadworks');
    cy.pickCategory('Pothole');
    cy.nextPageReporting();
    cy.contains('Roadworks are scheduled near this location').should('be.visible');
    cy.contains('Parapet improvement').should('be.visible');
    cy.go('back');
    cy.pickCategory('Fallen branch');
    cy.nextPageReporting();
    cy.should('not.contain', 'Roadworks are scheduled near this location');
  });

});
